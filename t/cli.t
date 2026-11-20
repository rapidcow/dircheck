#!perl
#
# t/cli.t - dircheck options and exit status

use 5.008;
use strict;
use warnings;
use Test::More tests => 7;
use File::Spec;
use FindBin;

my $script = File::Spec->catfile($FindBin::Bin, File::Spec->updir,
	'blib', 'script', 'dircheck');
-f $script or $script = File::Spec->catfile($FindBin::Bin,
	File::Spec->updir, 'script', 'dircheck');

local $ENV{LC_ALL} = 'C';
delete $ENV{DIRCHECK_CODESETS};

sub run
{
	my $cmd = join ' ', map { "'$_'" } $^X, (map { "-I$_" } @INC),
		$script, @_;
	my $out = `$cmd 2>&1`;
	($? >> 8, $out);
}

my ($status, $out) = run('-V');
is($status, 0, '-V exits 0');
like($out, qr/\Adircheck version 0\.00_00\n\z/, '-V prints the version');

($status, $out) = run('-h');
is($status, 0, '-h exits 0');
like($out, qr/\Ausage: dircheck /, '-h prints usage');

($status, $out) = run('-x');
is($status, 2, 'unknown option exits 2');

($status, $out) = run(File::Spec->catfile($FindBin::Bin, 'no-such-spec'));
is($status, 1, 'missing spec exits 1');
like($out, qr/\Adircheck: cannot open /, 'missing spec says so');
