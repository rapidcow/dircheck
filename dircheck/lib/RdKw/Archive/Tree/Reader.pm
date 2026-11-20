package RdKw::Archive::Tree::Reader;

use 5.008;
use strict;
use warnings;

use version;
our $VERSION = '0.00_00';
$VERSION = version->parse( $VERSION );

use charnames ();
use MIME::Base64 ();

=head1 NAME

RdKw::Archive::Tree::Reader - read a dircheck tree specification

=head1 SYNOPSIS

    use RdKw::Archive::Tree::Reader;
    my $reader = RdKw::Archive::Tree::Reader->new(file => 'tree.spec');
    my @entries = $reader->parse($text);   # $text is a character string

=head1 DESCRIPTION

Reads the text of a specification (see L<RdKw::Archive::Tree>) and
returns its entries in order, with every C<#(set ...)> applied.  Each
entry is a hash reference:

    { name => 'index.html', line => 3, keys => { type => 'file', ... } }
    { up => 1, line => 9 }          # `..'

The first entry is always the top directory, C<< name => '.' >>,
with only the keys that a C<.> line gave it.  The last entries close
every directory that the text left open, the top one included.

The values in I<keys> are normalized:

=over

=item B<type>

C<tree>, C<file> or C<link>.

=item B<uid>, B<gid>, B<nlink>, B<size>, B<cksum>

A string of decimal digits.

=item B<mode>

A number from 0 to 07777.

=item B<time>

An array reference: seconds since the epoch (a string of decimal
digits), nanoseconds (nine digits), and the ISO 8601 string as written,
or undef if an epoch was written.

=item B<uname>, B<gname>, B<link>, B<flags>

A character string.

=item B<ignore>, B<nochange>, B<optional>

1 (a key whose value is C<#f> is left out).

=item B<digest.>I<algorithm>

A byte string of the length that the algorithm makes.

=back

Errors die with C<I<file>:I<line>: I<message>>, ended by a newline.

=head1 METHODS

=over

=item I<CLASS>->B<new>( B<file> => I<name> )

A reader whose errors name I<name> (C<-> by default).

=cut

sub new
{
	my ($class, %opt) = @_;
	bless { file => defined $opt{file} ? $opt{file} : '-' }, $class;
}

=item I<reader>->B<parse>( I<text> )

The entries of I<text>, a character string (decoded from UTF-8).

=back

=cut

# Digest name => length in bytes
our %DIGEST = (
	md5    => 16,
	sha1   => 20,
	rmd160 => 20,
	sha256 => 32,
	sha384 => 48,
	sha512 => 64,
);

# Key => how its value is checked and normalized
my %KEY = (
	type     => \&_val_type,
	uid      => \&_val_uint,
	gid      => \&_val_uint,
	nlink    => \&_val_uint,
	size     => \&_val_uint,
	cksum    => \&_val_uint,
	mode     => \&_val_mode,
	time     => \&_val_time,
	uname    => \&_val_text,
	gname    => \&_val_text,
	link     => \&_val_text,
	flags    => \&_val_text,
	ignore   => \&_val_bool,
	nochange => \&_val_bool,
	optional => \&_val_bool,
	map { ("digest.$_" => \&_val_digest) } keys %DIGEST,
);

# mtree(5) names that are spelled otherwise here
my %RENAMED = (
	dir => 'tree',
	(map { ("${_}digest" => "digest.$_") } keys %DIGEST),
	sha1digest => 'digest.sha1',
	ripemd160digest => 'digest.rmd160',
);

sub parse
{
	my ($self, $text) = @_;
	$self->{text} = $text;
	$self->{pos} = 0;
	$self->{line} = 1;

	my @out = ({ name => '.', line => 0, keys => {} });
	# One frame per open directory: the defaults that #(set) made in it
	my @stack = ({});
	my $nodes = 0;

	for (;;) {
		my $tok = $self->_token('line');
		last if $tok->[0] eq 'eof';
		next if $tok->[0] eq 'nl';
		my $line = $tok->[2];
		my ($verb, $name, @pairs);
		if ($tok->[0] eq 'open') {
			($verb, $name, @pairs) = $self->_directive();
			$self->_end_of_line();
		} else {
			$verb = 'node';
			$name = $self->_name($tok);
			while (( $tok = $self->_token('line') )->[0] ne 'nl'
				&& $tok->[0] ne 'eof')
			{
				push @pairs, $self->_pair($tok, 'line');
			}
		}

		if ($verb eq 'set') {
			my $frame = $stack[-1];
			while (@pairs) {
				my ($k, $v) = splice @pairs, 0, 2;
				defined $v ? ($frame->{$k} = $v) : delete $frame->{$k};
			}
			next;
		}
		if ($verb eq 'unset') {
			delete @{ $stack[-1] }{@pairs};
			next;
		}

		# A node
		if ($name eq '..') {
			@pairs and $self->_die("`..' takes no keys", $line);
			@stack > 1 or $self->_die("`..' above the top directory", $line);
			pop @stack;
			push @out, { up => 1, line => $line };
			$nodes++;
			next;
		}
		if ($name eq '.') {
			($nodes || @stack > 1)
				and $self->_die("`.' must be the first node", $line);
			my %keys;
			while (@pairs) {
				my ($k, $v) = splice @pairs, 0, 2;
				defined $v and $keys{$k} = $v;
			}
			defined $keys{type} && $keys{type} ne 'tree'
				and $self->_die("`.' is a tree", $line);
			$out[0] = { name => '.', line => $line, keys => \%keys };
			$nodes++;
			next;
		}
		my %keys = %{ $stack[-1] };
		while (@pairs) {
			my ($k, $v) = splice @pairs, 0, 2;
			defined $v ? ($keys{$k} = $v) : delete $keys{$k};
		}
		my $type = defined $keys{type} ? $keys{type} : '';
		if ($type eq 'link') {
			defined $keys{link}
				or $self->_die("link `$name' has no `link' key", $line);
		} elsif (defined $keys{link}) {
			$self->_die("`link' key on `$name', which is not a link", $line);
		}
		if ($type ne 'file') {
			for (sort grep { /^digest\./ } keys %keys) {
				$self->_die("`$_' key on `$name', which is not a file", $line);
			}
		}
		push @out, { name => $name, line => $line, keys => \%keys };
		$nodes++;
		if ($type eq 'tree') {
			push @stack, { %{ $stack[-1] } };
		}
	}

	while (@stack > 1) {
		pop @stack;
		push @out, { up => 1, line => $self->{line} };
	}
	push @out, { up => 1, line => $self->{line} };
	delete @$self{qw( text pos )};
	@out;
}

# --- Directives and lines

# #( verb ... ): the cursor is past `#('.
# Returns (verb, name, pairs) for node and set, (verb, undef, keys) for unset.
sub _directive
{
	my ($self) = @_;
	my $tok = $self->_token('free');
	$tok->[0] eq 'word' or $self->_die('expected a directive name after `#(\'');
	my $verb = $tok->[1];
	my ($name, @rest);
	if ($verb eq 'node') {
		$tok = $self->_token('free');
		$tok->[0] eq 'close' and $self->_die('`#(node)\' needs a name');
		$name = $self->_name($tok);
	} elsif ($verb ne 'set' && $verb ne 'unset') {
		$self->_die("unknown directive `$verb' (only set, unset and node)");
	}
	while (( $tok = $self->_token('free') )->[0] ne 'close') {
		$tok->[0] eq 'eof' and $self->_die('unterminated `#(\'');
		if ($verb eq 'unset') {
			push @rest, $self->_key($tok);
		} else {
			push @rest, $self->_pair($tok, 'free');
		}
	}
	($verb, $name, @rest);
}

sub _end_of_line
{
	my ($self) = @_;
	my $tok = $self->_token('line');
	$tok->[0] eq 'nl' || $tok->[0] eq 'eof'
		or $self->_die('expected the end of the line after `)\'');
}

# The first token of a node: the name of a file, as written
sub _name
{
	my ($self, $tok) = @_;
	my ($kind, $text) = @$tok;
	if ($kind eq 'word') {
		$text =~ /\A#/
			and $self->_die("names cannot start with `#'; quote it: \"$text\"");
		return $text if $text eq '.' || $text eq '..';
	} elsif ($kind eq 'bytes') {
		$self->_die('a file name must be a string, not a byte string');
	} elsif ($kind ne 'str') {
		$self->_die('expected a file name');
	}
	length $text or $self->_die('empty file name');
	$text eq '.' || $text eq '..'
		and $self->_die("\"$text\" is not a file name; write $text bare");
	$text =~ m!/! and $self->_die('a file name cannot contain `/\'');
	$text =~ /\0/ and $self->_die('a file name cannot contain NUL');
	$text;
}

sub _key
{
	my ($self, $tok) = @_;
	my ($kind, $text) = @$tok;
	($kind eq 'word' && $text !~ /\A#/) || $kind eq 'str'
		or $self->_die('expected a key');
	unless ($KEY{$text}) {
		my $hint = $RENAMED{$text};
		$self->_die("unknown key `$text'"
			. (defined $hint ? "; write `$hint'" : ''));
	}
	$text;
}

# (key, value) from a key token and the token after it; value undef is ()
sub _pair
{
	my ($self, $tok, $mode) = @_;
	my $key = $self->_key($tok);
	my $vtok = $self->_token($mode);
	my $val = $self->_value($vtok);
	return ($key, undef) if $val->[0] eq 'null';
	($key, $KEY{$key}->($self, $key, $val));
}

# [kind, text, extra] from a token:
#   str (text), num (decimal text, leading zero), bool (0 or 1),
#   bytes (octets), null
sub _value
{
	my ($self, $tok) = @_;
	my ($kind, $text) = @$tok;
	return [ $kind, $text ] if $kind eq 'str' || $kind eq 'bytes' || $kind eq 'null';
	$kind eq 'word' or $self->_die('expected a value');
	if ($text =~ /\A#(?:t|true)\z/) { return [ bool => 1 ] }
	if ($text =~ /\A#(?:f|false)\z/) { return [ bool => 0 ] }
	if ($text =~ /\A#([xXoObBdD])(.*)\z/s) {
		my ($r, $body) = (lc $1, $2);
		my $radix = { x => 16, o => 8, b => 2, d => 10 }->{$r};
		return [ num => $self->_number($body, $radix, $text), 0 ];
	}
	$text =~ /\A#/ and $self->_die("reserved syntax `$text'");
	if ($text =~ /\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)\z/) {
		my $lead = $text =~ /\A[+-]?0[0-9]/ ? 1 : 0;
		return [ num => $self->_number($text, 10, $text), $lead ];
	}
	$text =~ /\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)[eE]/
		and $self->_die("exponents are not supported: `$text'");
	[ str => $text ];
}

# Digits in a radix to a decimal string (a fraction only in base 10)
sub _number
{
	my ($self, $body, $radix, $raw) = @_;
	my $sign = $body =~ s/\A([+-])// ? $1 : '';
	my $frac = '';
	if ($radix == 10 && $body =~ s/\.([0-9]*)\z//) {
		$frac = $1;
		length $body or $body = '0';
	}
	my $digit = { 2 => '[01]', 8 => '[0-7]', 10 => '[0-9]',
		16 => '[0-9a-fA-F]' }->{$radix};
	$body =~ /\A(?:$digit)+\z/ or $self->_die("bad number `$raw'");
	my $dec = '0';
	if ($radix == 10) {
		($dec = $body) =~ s/\A0+(?=.)//;
	} else {
		for my $d (split //, $body) {
			$dec = _mul_add($dec, $radix, hex $d);
		}
	}
	$frac =~ s/0+\z//;
	my $out = $dec . (length $frac ? ".$frac" : '');
	$sign eq '-' && $out =~ /[1-9]/ ? "-$out" : $out;
}

# $dec * $m + $a, in decimal strings, with no overflow
sub _mul_add
{
	my ($dec, $m, $a) = @_;
	my @d = reverse split //, $dec;
	my $carry = $a;
	for (@d) {
		my $v = $_ * $m + $carry;
		$_ = $v % 10;
		$carry = int($v / 10);
	}
	while ($carry) { push @d, $carry % 10; $carry = int($carry / 10) }
	my $out = join '', reverse @d;
	$out =~ s/\A0+(?=.)//;
	$out;
}

# --- Values of keys

sub _val_type
{
	my ($self, $key, $v) = @_;
	$v->[0] eq 'str' or $self->_die('`type\' is tree, file or link');
	my $t = $v->[1];
	return $t if $t eq 'tree' || $t eq 'file' || $t eq 'link';
	my $hint = $RENAMED{$t};
	$self->_die("unknown type `$t'" . (defined $hint ? "; write `$hint'" : ''));
}

sub _val_uint
{
	my ($self, $key, $v) = @_;
	my $text = _numeric_text($v);
	defined $text && $text =~ /\A[0-9]+\z/
		or $self->_die("`$key' is a whole number");
	$text;
}

sub _val_mode
{
	my ($self, $key, $v) = @_;
	my $text = _numeric_text($v);
	defined $text && $text =~ /\A[0-9]+\z/
		or $self->_die('`mode\' is a whole number, such as #o644');
	($v->[0] eq 'num' ? $v->[2] : $v->[1] =~ /\A0[0-9]/)
		and $self->_die("`mode' is decimal here; write octal as #o"
			. do { (my $o = $v->[1]) =~ s/\A[+]?0+(?=[0-9])//; $o });
	length $text <= 4 && $text <= 07777
		or $self->_die('`mode\' is greater than #o7777');
	0 + $text;
}

# The decimal text of a number, or of a string that is one
sub _numeric_text
{
	my ($v) = @_;
	return $v->[1] if $v->[0] eq 'num';
	return $v->[1] if $v->[0] eq 'str' && $v->[1] =~ /\A[0-9]+\z/;
	undef;
}

sub _val_text
{
	my ($self, $key, $v) = @_;
	$v->[0] eq 'str' || $v->[0] eq 'num'
		or $self->_die("`$key' is a string");
	length $v->[1] or $self->_die("`$key' is empty");
	$v->[1];
}

sub _val_bool
{
	my ($self, $key, $v) = @_;
	$v->[0] eq 'bool' or $self->_die("`$key' is #t or #f");
	# #f is the same as leaving the key out
	$v->[1] ? 1 : undef;
}

sub _val_digest
{
	my ($self, $key, $v) = @_;
	$v->[0] eq 'bytes' or $self->_die("`$key' is a byte string #\"...\"");
	(my $alg = $key) =~ s/\Adigest\.//;
	my $want = $DIGEST{$alg};
	length $v->[1] == $want
		or $self->_die("`$key' is $want bytes, not " . length($v->[1]));
	$v->[1];
}

sub _val_time
{
	my ($self, $key, $v) = @_;
	if ($v->[0] eq 'num' || ($v->[0] eq 'str' && $v->[1] =~ /\A[0-9]+(?:\.[0-9]+)?\z/)) {
		my ($sec, $frac) = $v->[1] =~ /\A([0-9]+)(?:\.([0-9]+))?\z/
			or $self->_die('`time\' in seconds cannot be negative');
		$frac = '' unless defined $frac;
		length $frac <= 9 or $self->_die('`time\' has more than 9 decimals');
		return [ $sec, substr($frac . '0' x 9, 0, 9), undef ];
	}
	$v->[0] eq 'str' or $self->_die('`time\' is an ISO 8601 string or seconds');
	my $iso = $v->[1];
	my ($y, $mo, $d, $h, $mi, $s, $frac, $tz) = $iso =~ /\A
		([0-9]{4})-([0-9][0-9])-([0-9][0-9]) T ([0-9][0-9]):([0-9][0-9]):([0-9][0-9]) (?:[.,]([0-9]{1,9}))?
		(Z|[+-][0-9][0-9](?::?[0-9][0-9])?) \z/x
		or $self->_die("`time' is not YYYY-MM-DDThh:mm:ss[.f] with Z or an offset: \"$iso\"");
	my $mdays = (31, (($y % 4 == 0 && $y % 100 != 0) || $y % 400 == 0) ? 29 : 28,
		31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[$mo - 1];
	$mo >= 1 && $mo <= 12 && $d >= 1 && $d <= $mdays
		&& $h <= 23 && $mi <= 59 && $s <= 59
		or $self->_die("`time' is not a real time: \"$iso\"");
	my $off = 0;
	if ($tz ne 'Z') {
		my ($sg, $oh, $om) = $tz =~ /\A([+-])([0-9][0-9]):?([0-9][0-9])?\z/;
		$om = 0 unless defined $om;
		$oh <= 23 && $om <= 59 or $self->_die("bad offset in \"$iso\"");
		$off = ($sg eq '-' ? -1 : 1) * ($oh * 3600 + $om * 60);
	}
	my $sec = _days_from_civil($y, $mo, $d) * 86400
		+ $h * 3600 + $mi * 60 + $s - $off;
	$sec >= 0 or $self->_die("`time' is before 1970: \"$iso\"");
	$frac = '' unless defined $frac;
	[ "$sec", substr($frac . '0' x 9, 0, 9), $iso ];
}

# Days from 1970-01-01 (Howard Hinnant's days_from_civil)
sub _days_from_civil
{
	my ($y, $m, $d) = @_;
	$y -= $m <= 2;
	my $era = int(($y >= 0 ? $y : $y - 399) / 400);
	my $yoe = $y - $era * 400;
	my $doy = int((153 * ($m + ($m > 2 ? -3 : 9)) + 2) / 5) + $d - 1;
	my $doe = $yoe * 365 + int($yoe / 4) - int($yoe / 100) + $doy;
	$era * 146097 + $doe - 719468;
}

# --- Tokens

my $SPACE = qr/[ \t\r\f\x0b]/;
# What ends a bare word
my $DELIM = qr/[ \t\r\f\x0b\n()\[\]{}"|;\\]/;

# The next token, as [kind, text, line]:
#   word, str, bytes, null, open (#(), close ()), nl, eof
# In `line' mode, a line feed is a token, and `\' before one (and maybe
# a comment) continues the line, past lines that are blank or only a
# comment.  In `free' mode, a line feed is a space.
sub _token
{
	my ($self, $mode) = @_;
	my $t = \$self->{text};
	for (;;) {
		pos($$t) = $self->{pos};
		$$t =~ /\G$SPACE*/gc;
		$$t =~ /\G;[^\n]*/gc;
		$self->{pos} = pos($$t);
		my $line = $self->{line};
		my $c = substr($$t, $self->{pos}, 1);
		if ($c eq '') {
			return [ eof => undef, $line ];
		}
		if ($c eq "\n") {
			$self->{pos}++;
			$self->{line}++;
			next if $mode eq 'free';
			return [ nl => undef, $line ];
		}
		if ($c eq '\\') {
			$mode eq 'line' or $self->_die('stray `\\\'');
			pos($$t) = $self->{pos} + 1;
			$$t =~ /\G$SPACE*(?:;[^\n]*)?(?:\n|\z)/gc
				or $self->_die('`\\\' continues a line only at its end');
			$self->{pos} = pos($$t);
			$self->{line}++;
			# Skip blank and comment-only lines
			while ($$t =~ /\G$SPACE*(?:;[^\n]*)?\n/gc) {
				$self->{pos} = pos($$t);
				$self->{line}++;
			}
			next;
		}
		$self->{pos}++;
		if ($c eq '"') {
			return [ str => $self->_string(), $line ];
		}
		if ($c eq ')') {
			return [ close => undef, $line ];
		}
		if ($c eq '(') {
			pos($$t) = $self->{pos};
			$$t =~ /\G$SPACE*\)/gc
				or $self->_die('`(\' starts a list, which is not allowed; `()\' is null');
			$self->{pos} = pos($$t);
			return [ null => undef, $line ];
		}
		if ($c eq '#') {
			my $n = substr($$t, $self->{pos}, 1);
			if ($n eq '(') {
				$self->{pos}++;
				return [ open => undef, $line ];
			}
			if ($n eq '"') {
				$self->{pos}++;
				return [ bytes => $self->_bytes(), $line ];
			}
			($n =~ /\A[|;\\]\z/
				|| substr($$t, $self->{pos}, 3) =~ /\Au8[("]/)
				and $self->_die("`#$n' is reserved");
		}
		$c =~ /\A[\[\]{}|]\z/ and $self->_die("`$c' is reserved");
		pos($$t) = $self->{pos};
		$$t =~ /\G((?:(?!$DELIM).)*)/gcs;
		$self->{pos} = pos($$t);
		return [ word => $c . $1, $line ];
	}
}

sub _getc
{
	my ($self) = @_;
	my $c = substr($self->{text}, $self->{pos}, 1);
	return undef if $c eq '';
	$self->{pos}++;
	$self->{line}++ if $c eq "\n";
	$c;
}

sub _ungetc
{
	my ($self, $c) = @_;
	return unless defined $c;
	$self->{pos}--;
	$self->{line}-- if $c eq "\n";
}

# --- Strings (as libexpr's DataLoader reads them)

sub _string
{
	my ($self) = @_;
	my $out = '';
	for (;;) {
		my $c = $self->_getc();
		defined $c or $self->_die('unterminated string "..."');
		return $out if $c eq '"';
		if ($c ne '\\') {
			$out .= $c;
			next;
		}
		$c = $self->_getc();
		defined $c or $self->_die('unterminated string "..."');
		$out .= $self->_escape($c);
	}
}

sub _bytes
{
	my ($self) = @_;
	my $out = '';
	for (;;) {
		my $c = $self->_getc();
		defined $c or $self->_die('unterminated byte string #"..."');
		return $out if $c eq '"';
		if ($c ne '\\') {
			ord $c < 128
				or $self->_die('non-ASCII character in byte string; use an escape');
			$out .= $c;
			next;
		}
		$c = $self->_getc();
		defined $c or $self->_die('unterminated byte string #"..."');
		$out .= $self->_octet_escape($c);
	}
}

my %SIMPLE = (
	a => "\007", b => "\010", t => "\011", n => "\012", v => "\013",
	f => "\014", r => "\015", e => "\033", s => ' ',
);

my %RADIX = ( x => 16, o => 8, d => 10, m => 2 );
# Digits that an escape without braces takes at most, for a character
my %WIDTH = ( x => 2, o => 3, d => 3, m => 8 );

# R7RS character names; also aliases for \N{...}
my %CHAR_NAME = (
	alarm => 0x07, backspace => 0x08, delete => 0x7f, escape => 0x1b,
	newline => 0x0a, null => 0x00, return => 0x0d, space => 0x20,
	tab => 0x09,
);

# The escape after `\' in a string; $c is the letter
sub _escape
{
	my ($self, $c) = @_;
	return $SIMPLE{$c} if exists $SIMPLE{$c};
	if ($c eq 'N') {
		return chr $self->_escape_name();
	}
	if ($c eq 'c' || $c eq '^') {
		my $w = $self->_getc();
		defined $w && ord $w < 128
			or $self->_die('expected an ASCII character after control escape');
		return chr(ord($w) ^ 64);
	}
	if ($RADIX{$c} || $c =~ /\A[0-7]\z/) {
		my ($radix, $width) = $RADIX{$c} ? ($RADIX{$c}, $WIDTH{$c}) : (8, 3);
		$self->_ungetc($c) unless $RADIX{$c};
		my $cp;
		if ($RADIX{$c} && substr($self->{text}, $self->{pos}, 1) eq '{') {
			$self->{pos}++;
			$cp = $self->_braced_number($radix);
		} else {
			$cp = $self->_bare_number($radix, $width);
		}
		return $self->_chr($cp);
	}
	if ($c =~ /\A[ \t\r\n]\z/) {
		# `\' at the end of a line: drop the line feed and the indent
		my $t = \$self->{text};
		$self->{line}-- if $c eq "\n";
		pos($$t) = $self->{pos} - 1;
		$$t =~ /\G[ \t]*(?:\r\n|\r|\n)[ \t]*/gc
			or $self->_die('expected a line ending after `\\\' in string');
		$self->{pos} = pos($$t);
		$self->{line}++;
		return '';
	}
	$c;
}

sub _chr
{
	my ($self, $cp) = @_;
	$cp <= 0x10FFFF or $self->_die('invalid code point');
	$cp >= 0xD800 && $cp <= 0xDFFF and $self->_die('surrogate code point');
	chr $cp;
}

# \N{...}: an R7RS name or a Unicode name, after `N'
sub _escape_name
{
	my ($self) = @_;
	defined(my $c = $self->_getc()) or $self->_die('expected `{\' after \\N');
	$c eq '{' or $self->_die('expected `{\' after \\N');
	my $t = \$self->{text};
	pos($$t) = $self->{pos};
	$$t =~ /\G([^}]*)\}/gc or $self->_die('unterminated name escape');
	$self->{pos} = pos($$t);
	my $name = $1;
	$name =~ s/\A[ \t]+//;
	$name =~ s/[ \t]+\z//;
	my $alias = $CHAR_NAME{lc $name};
	return $alias if defined $alias;
	my $cp = charnames::vianame(uc $name);
	defined $cp or $self->_die("unknown character name: $name");
	$cp;
}

# Up to $width digits; at least one
sub _bare_number
{
	my ($self, $radix, $width) = @_;
	my ($value, $count) = (0, 0);
	while ($count < $width) {
		my $c = $self->_getc();
		my $d = _digit($c, $radix);
		unless (defined $d) {
			$self->_ungetc($c);
			last;
		}
		$value = $value * $radix + $d;
		$count++;
	}
	$count or $self->_die("expected a base-$radix digit in escape");
	$value;
}

# The digits of a braced escape in a string, after `{': spaces, `-', `_'
# and `;' comments are skipped; empty braces are 0
sub _braced_number
{
	my ($self, $radix) = @_;
	my $value = 0;
	for (;;) {
		my $c = $self->_getc();
		defined $c or $self->_die('expected `}\' in escape');
		return $value if $c eq '}';
		if ($c eq ';') { $self->_skip_comment(); next }
		next if $c =~ /\A[ \t\n\r\f\x0b_-]\z/;
		my $d = _digit($c, $radix);
		defined $d or $self->_die("expected a base-$radix digit or `}' in escape");
		$value = $value * $radix + $d;
		$value <= 0x10FFFF or $self->_die('invalid code point');
	}
}

sub _skip_comment
{
	my ($self) = @_;
	my $t = \$self->{text};
	pos($$t) = $self->{pos};
	$$t =~ /\G[^\n]*/gc;
	$self->{pos} = pos($$t);
}

sub _digit
{
	my ($c, $radix) = @_;
	return undef unless defined $c && $c =~ /\A[0-9a-fA-F]\z/;
	my $d = hex $c;
	$d < $radix ? $d : undef;
}

# Digits for one octet in a byte string: 2 hex, 3 octal, 3 decimal, 8 binary
sub _bundle_width
{
	my ($radix) = @_;
	my $n = 1;
	for (my $max = $radix; $max < 256; $max *= $radix) { $n++ }
	$n;
}

sub _octet
{
	my ($self, $v) = @_;
	$v <= 255 or $self->_die("octet $v out of range [0,256)");
	chr $v;
}

sub _octet_escape
{
	my ($self, $c) = @_;
	if ($c eq 'N') {
		return $self->_octet($self->_escape_name());
	}
	if ($c eq 'B') {
		return $self->_base64();
	}
	if ($RADIX{$c}) {
		my $radix = $RADIX{$c};
		if (substr($self->{text}, $self->{pos}, 1) eq '{') {
			$self->{pos}++;
			return $self->_braced_octets($radix);
		}
		return $self->_octet($self->_bare_number($radix, _bundle_width($radix)));
	}
	if ($c =~ /\A[0-7]\z/) {
		$self->_ungetc($c);
		return $self->_octet($self->_bare_number(8, 3));
	}
	my $s = $self->_escape($c);
	$s =~ /[^\x00-\x7f]/
		and $self->_die('non-ASCII character in byte string; use an escape');
	$s;
}

# \x{...} and friends in a byte string, after `{'.  A group of up to n
# digits (n from _bundle_width) is one octet; a longer group is split
# into groups of n.  `.' and `:' end a group.  `{}' is one zero octet.
sub _braced_octets
{
	my ($self, $radix) = @_;
	my $n = _bundle_width($radix);
	my ($out, @digits, $delimited) = ('');
	for (;;) {
		my $c = $self->_getc();
		defined $c or $self->_die('expected `}\' in escape');
		if ($c eq '}' || $c eq '.' || $c eq ':') {
			$delimited ||= $c ne '}';
			if (@digits) {
				@digits > $n && @digits % $n
					and $self->_die("expected a multiple of $n base-$radix"
						. " digits in octet escape, got " . @digits);
				while (@digits) {
					my $v = 0;
					$v = $v * $radix + $_ for splice @digits, 0, $n;
					$out .= $self->_octet($v);
				}
			} elsif ($c eq '}' && !$delimited) {
				$out .= "\0";
			} else {
				$self->_die('empty digit group in octet escape');
			}
			return $out if $c eq '}';
			next;
		}
		if ($c eq ';') { $self->_skip_comment(); next }
		next if $c =~ /\A[ \t\n\r\f\x0b_-]\z/;
		my $d = _digit($c, $radix);
		defined $d or $self->_die("expected a base-$radix digit or `}' in escape");
		push @digits, $d;
	}
}

# \B{...}: base64, spaces ignored, `-_.' for `+/=', padding optional
sub _base64
{
	my ($self) = @_;
	defined(my $c = $self->_getc()) or $self->_die('expected `{\' after \\B');
	$c eq '{' or $self->_die('expected `{\' after \\B');
	my $text = '';
	for (;;) {
		$c = $self->_getc();
		defined $c or $self->_die('expected `}\' in escape');
		last if $c eq '}';
		if ($c eq ';') { $self->_skip_comment(); next }
		next if $c =~ /\A[ \t\n\r\f\x0b]\z/;
		$c =~ tr/-_./+\/=/;
		$text .= $c;
	}
	(my $bare = $text) =~ s/=+\z//;
	$bare =~ m!\A[A-Za-z0-9+/]*\z! && length($bare) % 4 != 1
		&& length($text) - length($bare) <= 2
		&& (length($text) == length($bare) || length($text) % 4 == 0)
		or $self->_die('bad base64 in escape');
	MIME::Base64::decode_base64($bare);
}

sub _die
{
	my ($self, $msg, $line) = @_;
	$line = $self->{line} unless defined $line;
	die "$self->{file}:$line: $msg\n";
}

1;
__END__

=head1 SEE ALSO

L<RdKw::Archive::Tree>, L<RdKw::Archive::Tree::MTree>

=cut
