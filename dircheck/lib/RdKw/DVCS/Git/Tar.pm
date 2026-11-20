package RdKw::DVCS::Git::Tar;

use 5.008;
use strict;
use warnings;

use version;
our $VERSION = '0.00_00';
$VERSION = version->parse( $VERSION );

use IPC::Open2 ();
use RdKw::Archive::Ustar;

=head1 NAME

RdKw::DVCS::Git::Tar - write a Git tree as a ustar archive

=head1 SYNOPSIS

    use RdKw::DVCS::Git::Tar;
    my $git = RdKw::DVCS::Git::Tar->new(
        treeish => 'HEAD', paths => [ 'doc/./html' ], prefix => 'site/',
        uname => 'root', uid => 0, gname => 'wheel', gid => 0,
    );
    $git->write(\*STDOUT);

=head1 DESCRIPTION

Reads a tree from Git, as L<git-archive(1)> does, and writes it with
L<RdKw::Archive::Ustar>.  Every argument is bytes, as Git takes them.
It runs C<git> from C<PATH>, which finds the repository as it would
from the current directory (or C<GIT_DIR>).

=head2 Paths

A path names a tree or a file in I<treeish>, by components separated
by C</>.  The first C<.> component, if there is one, says where the
name in the archive starts: the components before it are kept and
the ones after it are not.

=over

=item C<doc/html>

Writes C<doc/>, C<doc/html/> and what is in C<doc/html>, as
git-archive does.

=item C<doc/./html>

Writes C<doc/> and what is in C<doc/html>, in C<doc/>: the file
C<doc/html/index.html> is C<doc/index.html>.

=item C<./doc/html>

Writes what is in C<doc/html>, with no directory: C<index.html>.

=back

What follows C<.> must be a tree.  No path, or C<.>, is the whole
tree.  Paths are written in the order given, each in Git's order.  A
directory that two paths write is written once; any other name that
two paths write is an error.

=head2 Attributes

As git-archive does, a path with the C<export-ignore> attribute is
not written, nor what is in it.  The attributes are read from
I<treeish> and from F<$GIT_DIR/info/attributes>, with C<git check-attr
--source>.  A file with the C<export-subst> attribute is an error.

=head1 METHODS

=over

=item I<CLASS>->B<new>( I<option> => I<value>, ... )

=over

=item B<treeish> => I<treeish>

The commit or tree (C<HEAD>).

=item B<paths> => [ I<path>, ... ]

What to write (all of it).

=item B<prefix> => I<prefix>

Put before every name, as git-archive's C<--prefix> is.  If it ends
with C</>, a directory entry is written for it.

=item B<mtime> => I<seconds>

The time of every entry: the committer's time, unless I<treeish> is a
tree, which is C<0>.

=item B<uname>, B<uid>, B<gname>, B<gid>

The owner of every entry (C<root>, C<0>, C<root>, C<0>).

=item B<fmask>, B<dmask>

What to clear from the mode of files (C<0666>, or C<0777> if the file
is executable) and of directories (C<0777>).  Both are C<022>.
Symbolic links are C<0777>.

=back

=cut

sub new
{
	my ($class, %opt) = @_;
	my $self = bless {
		treeish => 'HEAD', paths => [], prefix => '',
		fmask => 022, dmask => 022,
		uname => 'root', uid => 0, gname => 'root', gid => 0,
		tree_cache => {},
	}, $class;
	for my $k (qw( treeish paths prefix mtime fmask dmask
			uname uid gname gid )) {
		$self->{$k} = $opt{$k} if defined $opt{$k};
	}
	$self;
}

=item I<git>->B<write>( I<handle> )

Writes the archive.  It reads all of the tree before it writes, so
nothing is written if a path is wrong.

=back

=cut

sub write
{
	my ($self, $fh) = @_;
	my $treeish = $self->{treeish};
	$treeish ne '' && $treeish !~ /\A-/
		or die "not a tree-ish: \"$treeish\"\n";
	my ($commit) = $self->_git_maybe('rev-parse', '--verify', '-q',
		"$treeish^{commit}");
	my ($tree) = $self->_git_maybe('rev-parse', '--verify', '-q',
		"$treeish^{tree}");
	defined $tree or die "not a tree-ish: \"$treeish\"\n";
	$self->{root} = $tree;
	my $mtime = $self->{mtime};
	$mtime = defined $commit ? $self->_commit_time($commit) : 0
		unless defined $mtime;

	my @entries = $self->_entries;
	@entries = $self->_attributes(@entries);

	my $tar = RdKw::Archive::Ustar->new(fh => $fh, mtime => $mtime,
		map { $_ => $self->{$_} } qw( uid gid uname gname ));
	$tar->global(comment => $commit) if defined $commit;
	my $cat;
	for my $e (@entries) {
		my $type = $e->{type};
		if ($type eq 'tree' || $type eq 'commit') {
			$tar->dir(name => $e->{name}, id => $e->{oid},
				mode => 0777 & ~$self->{dmask});
			next;
		}
		$cat ||= $self->_open2('cat-file', '--batch');
		if ($e->{mode} eq '120000') {
			my $target = '';
			$self->_cat($cat, $e->{oid}, sub { $target .= $_[0] });
			$tar->symlink(name => $e->{name}, id => $e->{oid},
				target => $target);
			next;
		}
		my $size = $self->_cat($cat, $e->{oid});
		my $perm = oct($e->{mode}) & 0100 ? 0777 : 0666;
		$tar->file(name => $e->{name}, id => $e->{oid}, size => $size,
			mode => $perm & ~$self->{fmask},
			data => sub { $self->_cat($cat, undef, $_[0]) });
	}
	$self->_close2($cat) if $cat;
	$tar->finish;
}

# Entries: { name, path (in Git, or undef), mode, type, oid }
sub _entries
{
	my ($self) = @_;
	my (@entries, %seen);
	my $add = sub {
		my ($e) = @_;
		my $dir = $e->{type} eq 'tree' || $e->{type} eq 'commit';
		$e->{name} .= '/' if $dir;
		if (my $old = $seen{$e->{name}}) {
			return if $dir && $old eq 'dir';
			die "\"$e->{name}\" is in the archive twice\n";
		}
		$seen{$e->{name}} = $dir ? 'dir' : 'file';
		push @entries, $e;
	};
	my $prefix = $self->{prefix};
	$add->({ name => substr($prefix, 0, -1), path => undef,
		mode => '040000', type => 'tree', oid => $self->{root} })
		if $prefix =~ m{./\z};
	my @paths = @{ $self->{paths} };
	@paths = ('.') unless @paths;
	for my $arg (@paths) {
		my ($keep, $strip) = _split_path($arg);
		my @want = (@$keep, @$strip);
		my $obj = $self->_lookup($arg, @want);
		for my $i (1 .. @$keep) {
			my $node = $self->_lookup($arg, @$keep[0 .. $i - 1]);
			$node->{type} eq 'tree' or die "not a tree: \"$arg\"\n"
				if $i < @$keep || @$strip;
			$add->({ %$node, name => $prefix . join('/', @$keep[0 .. $i - 1]),
				path => join('/', @$keep[0 .. $i - 1]) });
		}
		if ($obj->{type} ne 'tree') {
			@$strip == 0 && @$keep or die "not a tree: \"$arg\"\n";
			next;
		}
		my $base = $prefix . join '', map { "$_/" } @$keep;
		my $in = join '', map { "$_/" } @want;
		for my $e ($self->_ls_tree('-r', '-t', $obj->{oid})) {
			$add->({ %$e, name => $base . $e->{name},
				path => $in . $e->{name} });
		}
	}
	@entries;
}

sub _split_path
{
	my ($arg) = @_;
	length $arg or die "empty path\n";
	$arg !~ m{\A/} or die "path is not relative: \"$arg\"\n";
	my (@keep, @strip, $dot);
	for my $c (split m{/+}, $arg) {
		if ($c eq '.') {
			$dot = 1;
			next;
		}
		$c ne '..' or die "path has `..': \"$arg\"\n";
		push @{ $dot ? \@strip : \@keep }, $c;
	}
	(\@keep, \@strip);
}

# What is at these components, as an entry
sub _lookup
{
	my ($self, $arg, @c) = @_;
	my $node = { mode => '040000', type => 'tree', oid => $self->{root} };
	for my $c (@c) {
		$node->{type} eq 'tree' or die "not a tree: \"$arg\"\n";
		my $list = $self->{tree_cache}{$node->{oid}} ||=
			{ map { $_->{name} => $_ } $self->_ls_tree($node->{oid}) };
		$node = $list->{$c} or die "not in $self->{treeish}: \"$arg\"\n";
	}
	$node;
}

sub _ls_tree
{
	my ($self, @args) = @_;
	my $out = join '', $self->_git('ls-tree', '-z', @args);
	map {
		my ($mode, $type, $oid, $name) = /\A(\d+) (\w+) (\w+)\t(.*)\z/s
			or die "cannot read git ls-tree: \"$_\"\n";
		{ mode => $mode, type => $type, oid => $oid, name => $name };
	} grep { length } split /\0/, $out;
}

sub _commit_time
{
	my ($self, $commit) = @_;
	my $text = join '', $self->_git('cat-file', 'commit', $commit);
	my ($head) = split /\n\n/, $text, 2;
	$head =~ /^committer .* ([0-9]+) [+-][0-9]{4}$/m
		or die "commit $commit has no committer time\n";
	$1;
}

sub _attributes
{
	my ($self, @entries) = @_;
	my @check = grep { defined $_->{path} } @entries;
	return @entries unless @check;
	my $p = $self->_open2('check-attr', '-z', '--stdin',
		"--source=$self->{root}", 'export-ignore', 'export-subst');
	my (%ignore, @out);
	local $/ = "\0";
	for my $e (@check) {
		print { $p->{in} } "$e->{path}\0";
		for (1 .. 2) {
			my @f = map { my $x = readline $p->{out};
				defined $x or die "git check-attr stopped\n";
				chop $x; $x } 1 .. 3;
			next if $f[2] eq 'unspecified' || $f[2] eq 'unset';
			$ignore{$e->{path}} = 1 if $f[1] eq 'export-ignore';
			die "export-subst is not supported: \"$e->{path}\"\n"
				if $f[1] eq 'export-subst' && $e->{type} eq 'blob';
		}
	}
	$self->_close2($p);
	ENTRY: for my $e (@entries) {
		if (defined(my $path = $e->{path})) {
			while (1) {
				next ENTRY if $ignore{$path};
				$path =~ s{/[^/]*\z}{} or last;
			}
		}
		push @out, $e;
	}
	@out;
}

# cat-file --batch: with an ID, asks for it and returns its size; if
# given code, also reads it all into the code.  With no ID, reads the
# rest of the last one into the code.
sub _cat
{
	my ($self, $p, $oid, $code) = @_;
	if (defined $oid) {
		print { $p->{in} } "$oid\n";
		local $/ = "\n";
		my $head = readline $p->{out};
		defined $head && $head =~ /\A\S+ \S+ ([0-9]+)\n\z/
			or die "git cat-file cannot read $oid\n";
		$p->{left} = $1;
		return $1 unless $code;
	}
	my $size = $p->{left};
	while ($p->{left} > 0) {
		my $n = $p->{left} > 65536 ? 65536 : $p->{left};
		my $buf;
		my $got = read $p->{out}, $buf, $n;
		$got or die "git cat-file stopped\n";
		$p->{left} -= $got;
		$code->($buf);
	}
	my $nl;
	read $p->{out}, $nl, 1;
	$size;
}

sub _open2
{
	my ($self, @args) = @_;
	my ($in, $out);
	my $pid = IPC::Open2::open2($out, $in, 'git', @args);
	binmode $_ for $in, $out;
	my $old = select $in; $| = 1; select $old;
	{ pid => $pid, in => $in, out => $out, what => "git $args[0]" };
}

sub _close2
{
	my ($self, $p) = @_;
	close $p->{in};
	close $p->{out};
	waitpid $p->{pid}, 0;
	$? == 0 or die "$p->{what} failed\n";
}

sub _git_maybe
{
	my ($self, @args) = @_;
	open my $fh, '-|', 'git', @args or die "cannot run git: $!\n";
	binmode $fh;
	my @out = <$fh>;
	close $fh;
	return if $?;
	chomp @out;
	@out;
}

sub _git
{
	my ($self, @args) = @_;
	open my $fh, '-|', 'git', @args or die "cannot run git: $!\n";
	binmode $fh;
	local $/;
	my $out = <$fh>;
	close $fh or die "git $args[0] failed\n";
	defined $out ? $out : '';
}

1;
__END__

=head1 SEE ALSO

L<RdKw::Archive::Ustar>, L<git-archive(1)>, L<dirc-git(1)>

=cut
