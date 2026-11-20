package RdKw::Archive::Ustar;

use 5.008;
use strict;
use warnings;

use version;
our $VERSION = '0.00_00';
$VERSION = version->parse( $VERSION );

=head1 NAME

RdKw::Archive::Ustar - write a ustar archive the way git-archive does

=head1 SYNOPSIS

    use RdKw::Archive::Ustar;
    my $tar = RdKw::Archive::Ustar->new(fh => \*STDOUT, mtime => 0);
    $tar->global(comment => $commit_hex);
    $tar->dir(name => 'a/', mode => 0755, id => $tree_hex);
    $tar->file(name => 'a/b', mode => 0644, size => 3, id => $blob_hex,
        data => sub { $_[0]->("hi\n") });
    $tar->symlink(name => 'a/c', target => 'b', id => $blob_hex);
    $tar->finish;

=head1 DESCRIPTION

Writes a POSIX ustar archive with pax headers, in the layout that
L<git-archive(1)> writes: every number is octal with leading zeros
and a NUL, the archive is a whole number of 10240-byte records, and
it ends with at least two zero blocks.

All names, targets, user names and group names are bytes.

A name longer than 100 bytes is split at a C</> into the C<prefix>
and C<name> fields, if it can be.  If it cannot be, the C<name> field
is I<id>C<.data> and a pax C<path> record has the name.  A link target
longer than 100 bytes is written as C<see >I<id>C<.paxheader> and a
pax C<linkpath> record.  A file of 8 GiB or more has its size in a pax
C<size> record.  The pax header is named I<id>C<.paxheader>.

=head1 METHODS

=over

=item I<CLASS>->B<new>( B<fh> => I<handle>, I<field> => I<value>, ... )

Writes to I<handle>, which should be binary.  The fields give every
header: B<mtime> (seconds, C<0>), B<uid> and B<gid> (C<0>), and
B<uname> and B<gname> (C<root>).

=cut

my $RECORD = 512;
my $BLOCK = 20 * $RECORD;
my $MAX_SIZE = 8 ** 11 - 1;

sub new
{
	my ($class, %opt) = @_;
	my $self = bless {
		fh => $opt{fh}, out => 0,
		mtime => 0, uid => 0, gid => 0, uname => 'root', gname => 'root',
	}, $class;
	for my $k (qw( mtime uid gid uname gname )) {
		$self->{$k} = $opt{$k} if defined $opt{$k};
	}
	my $max = { mtime => $MAX_SIZE, uid => oct '7777777',
		gid => oct '7777777' };
	for my $k (sort keys %$max) {
		$self->{$k} =~ /\A[0-9]+\z/ && $self->{$k} <= $max->{$k}
			or die "$k is not a number from 0 to $max->{$k}: $self->{$k}\n";
	}
	for my $k (qw( uname gname )) {
		length $self->{$k} <= 32 && $self->{$k} !~ /\0/
			or die "$k is longer than 32 bytes, or has a NUL\n";
	}
	$self;
}

=item I<tar>->B<global>( I<key> => I<value>, ... )

A pax global header (C<pax_global_header>) with these records, in
order.  git-archive writes C<comment> with the commit ID.

=cut

sub global
{
	my ($self, @rec) = @_;
	my $ext = '';
	while (@rec) {
		my ($k, $v) = splice @rec, 0, 2;
		$ext .= _record($k, $v);
	}
	$self->_put(_header($self, name => 'pax_global_header', type => 'g',
		mode => 0666, size => length $ext));
	$self->_block($ext);
}

=item I<tar>->B<dir>( B<name> => I<name>, B<mode> => I<mode>, B<id> => I<id> )

A directory.  I<name> ends with C</>.

=item I<tar>->B<file>( B<name> => I<name>, B<mode> => I<mode>, B<size> => I<n>, B<id> => I<id>, B<data> => I<code> )

A regular file of I<n> bytes.  I<code> is called with a function that
writes bytes; it must write I<n> bytes in all.

=item I<tar>->B<symlink>( B<name> => I<name>, B<target> => I<target>, B<id> => I<id> )

A symbolic link.  Its mode is C<0777>.

=cut

sub dir
{
	my ($self, %e) = @_;
	$e{name} =~ m{/\z} or die "directory name does not end with /: $e{name}\n";
	$self->_entry(%e, type => '5', size => 0);
}

sub file
{
	my ($self, %e) = @_;
	$self->_entry(%e, type => '0');
	my $left = $e{size};
	$e{data}->(sub {
		my $n = length $_[0];
		$n <= $left or die "$e{name}: more than $e{size} bytes\n";
		$left -= $n;
		$self->_put($_[0]);
	});
	$left == 0 or die "$e{name}: fewer than $e{size} bytes\n";
	$self->_pad;
}

sub symlink
{
	my ($self, %e) = @_;
	$self->_entry(%e, type => '2', mode => 0777, size => 0);
}

=item I<tar>->B<finish>

Writes the end of the archive.

=back

=cut

sub finish
{
	my ($self) = @_;
	my $tail = $BLOCK - $self->{out} % $BLOCK;
	$tail += $BLOCK if $tail < 2 * $RECORD;
	$self->_put("\0" x $tail);
}

sub _entry
{
	my ($self, %e) = @_;
	my $ext = '';
	my %h = (type => $e{type}, mode => $e{mode}, size => $e{size});
	my $path = $e{name};
	length $path or die "empty name\n";
	if (length $path > 100) {
		my $i = length $path;
		$i-- if $i > 1 && substr($path, $i - 1, 1) eq '/';
		$i = 155 if $i > 155;
		do { $i-- } while $i > 0 && substr($path, $i, 1) ne '/';
		if ($i > 0 && length($path) - $i - 1 <= 100) {
			$h{prefix} = substr($path, 0, $i);
			$h{name} = substr($path, $i + 1);
		} else {
			$h{name} = _id(\%e) . '.data';
			$ext .= _record(path => $path);
		}
	} else {
		$h{name} = $path;
	}
	if (defined $e{target}) {
		if (length $e{target} > 100) {
			$h{link} = 'see ' . _id(\%e) . '.paxheader';
			$ext .= _record(linkpath => $e{target});
		} else {
			$h{link} = $e{target};
		}
	}
	if ($e{size} > $MAX_SIZE) {
		$h{size} = 0;
		$ext .= _record(size => $e{size});
	}
	if (length $ext) {
		$self->_put(_header($self, name => _id(\%e) . '.paxheader',
			type => 'x', mode => 0666, size => length $ext));
		$self->_block($ext);
	}
	$self->_put(_header($self, %h));
}

sub _id
{
	my ($e) = @_;
	defined $e->{id} or die "$e->{name}: name is too long, and has no ID\n";
	$e->{id};
}

# "%u key=value\n", where %u counts the whole record
sub _record
{
	my ($k, $v) = @_;
	my $base = length(" $k=\n") + length $v;
	my $n = $base + 1;
	$n = $base + length $n until $n == $base + length $n;
	"$n $k=$v\n";
}

sub _header
{
	my ($self, %h) = @_;
	my $b = pack 'a100 a8 a8 a8 a12 a12 a8 a1 a100 a6 a2 a32 a32 a8 a8 a155 a12',
		$h{name}, sprintf('%07o', $h{mode} & 07777),
		sprintf('%07o', $self->{uid}), sprintf('%07o', $self->{gid}),
		sprintf('%011o', $h{size}), sprintf('%011o', $self->{mtime}),
		' ' x 8, $h{type}, defined $h{link} ? $h{link} : '',
		'ustar', '00', $self->{uname}, $self->{gname},
		sprintf('%07o', 0), sprintf('%07o', 0),
		defined $h{prefix} ? $h{prefix} : '', '';
	substr($b, 148, 8) = pack 'a8', sprintf('%07o', unpack '%32C*', $b);
	$b;
}

sub _block
{
	my ($self, $data) = @_;
	$self->_put($data);
	$self->_pad;
}

sub _pad
{
	my ($self) = @_;
	my $n = -$self->{out} % $RECORD;
	$self->_put("\0" x $n) if $n;
}

sub _put
{
	my ($self, $data) = @_;
	print { $self->{fh} } $data or die "cannot write: $!\n";
	$self->{out} += length $data;
}

1;
__END__

=head1 SEE ALSO

L<RdKw::DVCS::Git::Tar>, L<git-archive(1)>, L<pax(1)>

=cut
