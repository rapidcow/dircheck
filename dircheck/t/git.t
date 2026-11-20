#!perl
#
# t/git.t - dirc-git against git archive

use 5.008;
use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw( tempdir );
use FindBin;

my $script = File::Spec->catfile($FindBin::Bin, File::Spec->updir,
	'blib', 'script', 'dirc-git');
-f $script or $script = File::Spec->catfile($FindBin::Bin,
	File::Spec->updir, 'script', 'dirc-git');

my ($ver) = `git --version 2>/dev/null` =~ /([0-9]+\.[0-9]+)/;
plan skip_all => 'needs git 2.40 or later'
	unless defined $ver && eval { version->parse("v$ver") >= version->parse('v2.40') };
plan tests => 22;

local $ENV{LC_ALL} = 'C.UTF-8';
delete $ENV{DIRCHECK_CODESETS};
delete @ENV{grep { /\AGIT_/ } keys %ENV};
$ENV{GIT_CONFIG_NOSYSTEM} = 1;
$ENV{HOME} = my $dir = tempdir(CLEANUP => 1);
my $repo = File::Spec->catdir($dir, 'repo');

sub sh
{
	my $cmd = join ' ', map { my $s = $_; $s =~ s/'/'\\''/g; "'$s'" } @_;
	my $out = `cd '$repo' && $cmd 2>&1`;
	$? == 0 or die "$cmd: $out";
	$out;
}

sub put
{
	my ($name, $data) = @_;
	my $path = File::Spec->catfile($repo, $name);
	my ($d) = $path =~ m{\A(.*)/};
	system('mkdir', '-p', $d) == 0 or die;
	open my $fh, '>', $path or die "$path: $!";
	binmode $fh;
	print $fh $data;
	close $fh;
}

sub dirc
{
	my $cmd = join ' ', map { my $s = $_; $s =~ s/'/'\\''/g; "'$s'" }
		$^X, (map { "-I$_" } @INC), $script, @_;
	my $err = File::Spec->catfile($dir, 'stderr');
	my $out = `cd '$repo' && $cmd 2>'$err'`;
	my $st = $? >> 8;
	open my $fh, '<', $err or die "$err: $!";
	local $/;
	($st, $out, scalar <$fh>);
}

sub git_out { sh('git', @_) }

sub names
{
	my ($tar) = @_;
	my @n;
	my $pos = 0;
	my $pax;
	while ($pos + 512 <= length $tar) {
		my $h = substr $tar, $pos, 512;
		last if $h eq "\0" x 512;
		my ($name, $size, $type, $prefix) = unpack 'Z100 x24 Z12 x20 a1 x255 Z155', $h;
		$size = oct $size;
		my $data = substr $tar, $pos + 512, $size;
		$pos += 512 + (($size + 511) & ~511);
		if ($type eq 'x') { ($pax) = $data =~ /path=(.*)\n/; next }
		next if $type eq 'g';
		$name = length $prefix ? "$prefix/$name" : $name;
		$name = $pax if defined $pax;
		undef $pax;
		push @n, $name;
	}
	join ' ', @n;
}

mkdir $repo or die "$repo: $!";
sh('git', 'init', '-q');
sh('git', 'config', 'user.name', 'T');
sh('git', 'config', 'user.email', 't@example.com');
put('README', "hello\n");
put('doc/html/index.html', "<p>\n");
put('doc/html/sub/a.css', "a\n");
put('doc/notes', "n\n");
put('bin/run', "#!/bin/sh\n");
sh('chmod', '755', 'bin/run');
sh('ln', '-s', '../README', 'doc/link');
sh('ln', '-s', 'x' x 120, 'doc/longlink');
my $long = join '/', ('d' x 60) x 3;
put("$long/f", "deep\n");
put(('n' x 120), "long name\n");
put("caf\xc3\xa9", "utf-8\n");
put('skip/me', "ignored\n");
put('.gitattributes', "skip export-ignore\n");
sh('git', 'add', '-A');
sh('git', 'update-index', '--add', '--cacheinfo',
	'160000,' . ('1' x 40) . ',mod');
local $ENV{GIT_COMMITTER_DATE} = '1795177170 -0600';
local $ENV{GIT_AUTHOR_DATE} = '1795177170 -0600';
sh('git', 'commit', '-q', '-m', 'one');
my $commit = git_out('rev-parse', 'HEAD');
chomp $commit;

for my $case (
	[ [], 'whole tree' ],
	[ [ '--prefix=pkg-1/', 'HEAD' ], 'prefix with /' ],
	[ [ '--prefix=pkg-', 'HEAD' ], 'prefix without /' ],
	[ [ 'HEAD', 'doc/html' ], 'path' ],
	[ [ 'HEAD', 'README', 'doc/html' ], 'two paths, in tree order' ],
	[ [ 'HEAD^{tree}' ], 'tree' ],
) {
	my ($args, $what) = @$case;
	my $want = git_out('archive', '--format=tar', @$args ? @$args : 'HEAD');
	my @time;
	if ($what eq 'tree') {
		# git archive gives a tree the time now
		@time = ('--mtime', oct unpack 'x136 Z12', $want);
	}
	my ($st, $got) = dirc('--umask', '002', @time, @$args);
	is($st, 0, "$what: exit 0");
	ok($got eq $want, "$what: the same as git archive");
}

my ($st, $tar) = dirc('HEAD', 'doc/./html');
is(names($tar), 'doc/ doc/index.html doc/sub/ doc/sub/a.css',
	'doc/./html is in doc/');
($st, $tar) = dirc('--prefix', 'p/', 'HEAD', './doc/html', 'doc/./link');
is($st, 1, 'a file cannot follow .');
($st, $tar) = dirc('--prefix', 'p/', 'HEAD', './doc/html', 'bin');
is(names($tar), 'p/ p/index.html p/sub/ p/sub/a.css p/bin/ p/bin/run',
	'./doc/html has no directory');

($st, $tar) = dirc('--gid', 'wheel:0', 'HEAD', 'bin');
my @h = map { substr $tar, $_ * 512, 512 } 0 .. 3;
is(unpack('x265 Z32', $h[2]) . ':' . unpack('x297 Z32', $h[2]),
	'root:wheel', 'owner and group names');
like($h[1], qr/\A52 comment=$commit\n/, 'commit ID');
is(join(' ', map { unpack 'x100 Z8', $_ } @h[2, 3]), '0000755 0000755',
	'umask 022');
is(oct unpack('x136 Z12', $h[2]), 1795177170, 'committer time');

my ($s1, $o1) = dirc('HEAD', '..');
is($s1, 1, '.. is an error');
($s1, undef, $o1) = dirc('HEAD', 'nope');
like($o1, qr/not in HEAD: "nope"/, 'a missing path says so');
($s1, $o1) = dirc('--uid', 'root', 'HEAD');
is($s1, 2, '--uid needs an ID');
