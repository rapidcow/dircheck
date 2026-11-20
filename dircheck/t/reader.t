#!perl
#
# t/reader.t - RdKw::Archive::Tree::Reader

use 5.008;
use strict;
use warnings;
use Test::More;

use RdKw::Archive::Tree::Reader;

sub parse
{
	RdKw::Archive::Tree::Reader->new(file => 't')->parse(@_);
}

# The nodes of a spec, as [name, keys] (and '..')
sub nodes
{
	my @e = parse(@_);
	shift @e;
	pop @e;
	[ map { $_->{up} ? '..' : [ $_->{name}, $_->{keys} ] } @e ];
}

# The keys of the only node of a spec
sub keys_of
{
	my ($text) = @_;
	my $n = nodes($text);
	$n->[0][1];
}

sub error_like
{
	my ($text, $re, $name) = @_;
	eval { parse($text) };
	like($@, $re, $name);
}

# --- Strings and byte strings

is_deeply(nodes(qq{"caf\\x{e9}"\n"\\x{1F 600}"\n"\\u"\n}),
	[ [ "caf\x{e9}", {} ], [ "\x{1F600}", {} ], [ 'u', {} ] ],
	'string escapes');
is_deeply(nodes(qq{"\\x41\\x4g\\101\\d065\\m1000001\\o{101}"}),
	[ [ "A\x04gAAAA", {} ] ], 'numeric escapes without braces');
is_deeply(nodes(qq{"\\N{SNOWMAN}\\N{ space }x\\cA"}),
	[ [ "\x{2603} x\x01", {} ] ], 'name and control escapes');
is_deeply(nodes(qq{"long \\\n    name"}),
	[ [ 'long name', {} ] ], 'backslash at the end of a line in a string');
error_like(qq{"\\x{D800}"}, qr/surrogate/, 'surrogates are refused');
error_like(qq{"\\xg"}, qr/base-16 digit/, '\\x needs a digit');

my $k = keys_of(qq{f type file digest.md5 #"\\x{d41d8cd9 8f00b204 e9800998 ecf8427e}"});
is(unpack('H*', $k->{'digest.md5'}), 'd41d8cd98f00b204e9800998ecf8427e',
	'\\x{...} in a byte string is octets');
$k = keys_of(qq{f type file digest.md5 #"\\x{c3a9}\\d{192.168.0.1}\\o{101 102}\\m{1}ab\\0\\377\\x{}cd"});
is(unpack('H*', $k->{'digest.md5'}), 'c3a9c0a80001414201616200ff006364',
	'octet groups');
$k = keys_of(qq{f type file digest.md5 #"\\B{ 1B2M2Y8AsgTpgAmY7PhCfg== }"});
is(unpack('H*', $k->{'digest.md5'}), 'd41d8cd98f00b204e9800998ecf8427e', 'base64');
$k = keys_of(qq{f type file digest.md5 #"\\B{1B2M2Y8AsgTpgAmY7PhCfg}"});
is(unpack('H*', $k->{'digest.md5'}), 'd41d8cd98f00b204e9800998ecf8427e', 'base64 without padding');
error_like(qq{f type file digest.md5 #"\\x{123}"}, qr/multiple of 2/, 'odd octet group');
error_like(qq{f type file digest.md5 #"\\x{e9}"}, qr/16 bytes, not 1/, 'digest length');
error_like(qq{f type file digest.md5 #"\x{e9}"}, qr/non-ASCII/, 'raw non-ASCII in bytes');
error_like(qq{f type file digest.md5 "abc"}, qr/byte string/, 'digest is bytes');
error_like(qq{f type file digest.whirlpool #""}, qr/unknown key/, 'unknown digest');
error_like(qq{f type file sha256digest #""}, qr/write `digest\.sha256'/, 'mtree digest name');

# --- Names

is_deeply(nodes(qq{404.html\n"#t"\n}),
	[ [ '404.html', {} ], [ '#t', {} ] ], 'a bare name is not a number');
error_like(qq{#t\n}, qr/cannot start with `#'/, 'bare # name');
error_like(qq{#"index.html"\n}, qr/not a byte string/, 'byte string name');
error_like(qq{"a/b"\n}, qr{contain `/'}, 'slash in name');
error_like(qq{".."\n}, qr/write \.\. bare/, 'quoted ..');
error_like(qq{..\n}, qr/above the top/, '.. at the top');
error_like(qq{a\n.\n}, qr/first node/, '. after a node');

# --- Values

$k = keys_of(qq{f uid #x1F5 gid 20 mode #o755 nlink "1" size #b101 cksum 007});
is_deeply($k, { uid => 501, gid => 20, mode => 0755, nlink => 1, size => 5,
	cksum => 7 }, 'numbers');
$k = keys_of(qq{f uid #x123456789ABCDEF0123});
is($k->{uid}, '5373003642731685151011', 'no overflow');
error_like(qq{f mode 0755}, qr/write octal as #o755/, 'mode with a leading zero');
error_like(qq{f mode "0644"}, qr/write octal as #o644/, 'mode string with a leading zero');
is(keys_of(qq{f mode 493})->{mode}, 0755, 'decimal mode');
error_like(qq{f mode #o17777}, qr/greater than/, 'mode range');
error_like(qq{f size 1e3}, qr/exponents/, 'no exponents');
error_like(qq{f uid -1}, qr/whole number/, 'negative uid');
is_deeply(keys_of(qq{f type "file" optional #t nochange #f}),
	{ type => 'file', optional => 1 }, 'symbols are strings; booleans');
error_like(qq{f type dir}, qr/write `tree'/, 'mtree type name');
error_like(qq{f type link}, qr/no `link' key/, 'link needs a target');
error_like(qq{f type file link x}, qr/not a link/, 'target needs a link');
error_like(qq{f (a)}, qr/not allowed/, 'no lists');
error_like(qq{f uid (\n)}, qr/not allowed/, 'null is on one line');

# --- Time

is_deeply(keys_of(qq{f time "2026-11-20T06:19:30-06:00"})->{time},
	[ '1795177170', '000000000', '2026-11-20T06:19:30-06:00' ], 'ISO with offset');
is_deeply(keys_of(qq{f time "2026-11-20T12:19:30.25Z"})->{time},
	[ '1795177170', '250000000', '2026-11-20T12:19:30.25Z' ], 'ISO Zulu, fraction');
is_deeply(keys_of(qq{f time "2000-02-29T05:30:00+0530"})->{time},
	[ '951782400', '000000000', '2000-02-29T05:30:00+0530' ], 'ISO leap day');
is_deeply(keys_of(qq{f time 1795177170.5})->{time},
	[ '1795177170', '500000000', undef ], 'epoch');
error_like(qq{f time "2026-11-20T06:19:30"}, qr/with Z or an offset/, 'offset required');
error_like(qq{f time "2026-02-29T00:00:00Z"}, qr/not a real time/, 'no such day');

# --- Lines, directives, scopes

is_deeply(nodes(<<'EOS'),
#(set type "file" uid 501 mode #o755)
a
"very-long-name" \
   ; whole comments

   mode #o644 \  ; trailing comment
   time 0
; a comment line ends nothing, but the line above has ended
src type tree
   #(set uid ())
   b
   #(node "c"
      type link link "../b")
..
d
#(unset uid mode)
e
EOS
	[
		[ 'a', { type => 'file', uid => 501, mode => 0755 } ],
		[ 'very-long-name', { type => 'file', uid => 501, mode => 0644,
			time => [ 0, '000000000', undef ] } ],
		[ 'src', { type => 'tree', uid => 501, mode => 0755 } ],
		[ 'b', { type => 'file', mode => 0755 } ],
		[ 'c', { type => 'link', mode => 0755, link => '../b' } ],
		'..',
		[ 'd', { type => 'file', uid => 501, mode => 0755 } ],
		[ 'e', { type => 'file' } ],
	], 'sets are scoped to their directory');

my @e = parse(qq{. uid 0\na type tree\nb type tree\n});
is_deeply([ map { $_->{up} ? '..' : $_->{name} } @e ],
	[ '.', 'a', 'b', '..', '..', '..' ], 'open directories are closed');
is_deeply($e[0]{keys}, { uid => 0 }, 'the . line');

error_like(qq{#(run x)}, qr/unknown directive/, 'reserved directive');
error_like(qq{#(set uid 1) a}, qr/end of the line/, 'nothing after a directive');
error_like(qq{#(set uid 1}, qr/unterminated/, 'unterminated directive');
error_like(qq{a \\ b}, qr/only at its end/, 'backslash in the middle');
error_like(qq{a [b]}, qr/reserved/, 'brackets are reserved');
error_like(qq{\n\na uid x}, qr/\At:3: /, 'errors name the line');

done_testing();
