#!perl
#
# t/cli.t - dircheck options and exit status

use 5.008;
use strict;
use warnings;
use Test::More tests => 15;
use File::Spec;
use File::Temp qw( tempdir );
use FindBin;

my $script = File::Spec->catfile($FindBin::Bin, File::Spec->updir,
	'blib', 'script', 'dircheck');
-f $script or $script = File::Spec->catfile($FindBin::Bin,
	File::Spec->updir, 'script', 'dircheck');

local $ENV{LC_ALL} = 'C.UTF-8';
delete $ENV{DIRCHECK_CODESETS};
my $dir = tempdir(CLEANUP => 1);

sub run
{
	my $cmd = join ' ', map { "'$_'" } $^X, (map { "-I$_" } @INC),
		$script, @_;
	my $out = `$cmd 2>&1`;
	($? >> 8, $out);
}

sub spec
{
	my ($name, $bytes) = @_;
	my $path = File::Spec->catfile($dir, $name);
	open my $fh, '>', $path or die "$path: $!";
	binmode $fh;
	print $fh $bytes;
	close $fh;
	$path;
}

my ($status, $out) = run('-V');
is($status, 0, '-V exits 0');
like($out, qr/\Adircheck version 0\.00_00\n\z/, '-V prints the version');

($status, $out) = run('-h');
is($status, 0, '-h exits 0');
like($out, qr/\Ausage: dircheck /, '-h prints usage');

($status, $out) = run('-x');
is($status, 2, 'unknown option exits 2');

($status, $out) = run('a', 'b');
is($status, 2, 'two specs exit 2');

($status, $out) = run(File::Spec->catfile($dir, 'no-such-spec'));
is($status, 1, 'missing spec exits 1');
like($out, qr/\Adircheck: cannot open /, 'missing spec says so');

my $good = spec('good', qq{"caf\xc3\xa9" type file mode #o644\n});
($status, $out) = run($good);
is($status, 0, 'a spec compiles');
is($out, "#mtree\n. type=dir\n    caf\\303\\251 type=file mode=0644\n..\n",
	'mtree on standard output');

my $o = File::Spec->catfile($dir, 'out');
($status, $out) = run('-o', $o, $good);
is($status . $out, '0', '-o writes nothing to standard output');
ok(-s $o, '-o writes the file');

my $bad = spec('bad', qq{a\nb mode 0644\n});
($status, $out) = run($bad);
is($status, 1, 'an error exits 1');
like($out, qr/\Adircheck: \Q$bad\E:2: .*#o644/, 'the error names the line');

($status, $out) = run(spec('latin1', qq{a\ncaf\xe9\n}));
like($out, qr/:2: not UTF-8/, 'the spec is UTF-8');
