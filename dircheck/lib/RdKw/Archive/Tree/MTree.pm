package RdKw::Archive::Tree::MTree;

use 5.008;
use strict;
use warnings;

use version;
our $VERSION = '0.00_00';
$VERSION = version->parse( $VERSION );

=head1 NAME

RdKw::Archive::Tree::MTree - write entries as mtree(5)

=head1 SYNOPSIS

    use RdKw::Archive::Tree::MTree;
    my $w = RdKw::Archive::Tree::MTree->new(to_fs => sub { $cs->to_fs(@_) });
    print $w->format(@entries);   # bytes

=head1 DESCRIPTION

Writes the entries that L<RdKw::Archive::Tree::Reader> returns as an
L<mtree(5)> specification in the relative format: a C<.> line, a line
for each node, and C<..> to leave each directory.  Every line has all
of its keywords; there is no C</set>.

The output is bytes.  File names, link targets, user names and group
names are spelled by I<to_fs> (as the file system spells them), and a
byte that is not printable ASCII, or is one of C<\ # = * ? [> or a
space, is written as C<\>I<ooo> (three octal digits).

Keys are renamed: C<tree> is C<dir>, C<digest.>I<alg> is
I<alg>C<digest> (hex), and C<time> is seconds and nine digits of
nanoseconds.  C<ignore>, C<nochange> and C<optional> are written bare.

=head1 METHODS

=over

=item I<CLASS>->B<new>( B<to_fs> => I<code> )

I<code> takes a character string and returns bytes, or dies.  By
default, strings are encoded as UTF-8.

=cut

sub new
{
	my ($class, %opt) = @_;
	my $to_fs = $opt{to_fs} || sub { my $s = shift; utf8::encode($s); $s };
	bless { to_fs => $to_fs }, $class;
}

=item I<w>->B<format>( I<entry>, ... )

The specification, as one byte string.

=back

=cut

my @ORDER = qw(
	type uid uname gid gname mode nlink size time link flags cksum
	digest.md5 digest.sha1 digest.rmd160
	digest.sha256 digest.sha384 digest.sha512
	ignore nochange optional
);

my %TYPE = ( tree => 'dir', file => 'file', link => 'link' );

sub format
{
	my ($self, @entries) = @_;
	my $out = "#mtree\n";
	my $depth = 0;
	for my $e (@entries) {
		if ($e->{up}) {
			$depth--;
			$out .= '    ' x ($depth < 0 ? 0 : $depth) . "..\n";
			next;
		}
		my %keys = %{ $e->{keys} };
		$keys{type} = 'tree' if $e->{name} eq '.';
		my @words = $e->{name} eq '.' ? '.' : $self->_vis($e->{name});
		for my $k (@ORDER) {
			defined(my $v = $keys{$k}) or next;
			push @words, $self->_keyword($k, $v);
		}
		$out .= '    ' x $depth . join(' ', @words) . "\n";
		$depth++ if defined $keys{type} && $keys{type} eq 'tree';
	}
	$out;
}

sub _keyword
{
	my ($self, $k, $v) = @_;
	return "type=$TYPE{$v}" if $k eq 'type';
	return sprintf('mode=%04o', $v) if $k eq 'mode';
	return "time=$v->[0].$v->[1]" if $k eq 'time';
	return $k if $k =~ /\A(?:ignore|nochange|optional)\z/;
	if ($k =~ /\Adigest\.(.*)\z/) {
		return "$1digest=" . unpack('H*', $v);
	}
	if ($k =~ /\A(?:uname|gname|link|flags)\z/) {
		return "$k=" . $self->_vis($v);
	}
	"$k=$v";
}

sub _vis
{
	my ($self, $name) = @_;
	my $bytes = $self->{to_fs}->($name);
	$bytes =~ s/([^\x21-\x7e]|[\\#=*?\[])/sprintf('\\%03o', ord $1)/ge;
	$bytes;
}

1;
__END__

=head1 SEE ALSO

L<RdKw::Archive::Tree>, L<mtree(5)>

=cut
