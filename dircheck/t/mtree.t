#!perl
#
# t/mtree.t - RdKw::Archive::Tree::MTree

use 5.008;
use strict;
use warnings;
use Test::More tests => 3;

use RdKw::Archive::Tree::MTree;
use RdKw::Archive::Tree::Reader;

sub mtree
{
	my ($text, @opt) = @_;
	my @e = RdKw::Archive::Tree::Reader->new(file => 't')->parse($text);
	RdKw::Archive::Tree::MTree->new(@opt)->format(@e);
}

is(mtree(<<'EOS'), <<'EOM', 'keywords, names and nesting');
#(set uid 501 gid 20 mode #o755)
"caf\x{e9} [*?]#=\\x" type file size 3 optional #t \
	time "2026-11-20T06:19:30-06:00" \
	digest.sha1 #"\x{da39a3ee 5e6b4b0d 3255bfef 95601890 afd80709}"
src type tree uname "r\x{e9}" flags uchg
	l type link link "../a b"
..
EOS
#mtree
. type=dir
    caf\303\251\040\133\052\077]\043\075\134x type=file uid=501 gid=20 mode=0755 size=3 time=1795177170.000000000 sha1digest=da39a3ee5e6b4b0d3255bfef95601890afd80709 optional
    src type=dir uid=501 uname=r\303\251 gid=20 mode=0755 flags=uchg
        l type=link uid=501 gid=20 mode=0755 link=../a\040b
    ..
..
EOM

is(mtree(". uid 0 mode #o700\n"), "#mtree\n. type=dir uid=0 mode=0700\n..\n",
	'the . line');

my $latin1 = sub { my $s = shift; die "cannot encode\n" if $s =~ /[^\x00-\xff]/; $s };
is(mtree(qq{"caf\\x{e9}"\n}, to_fs => $latin1),
	"#mtree\n. type=dir\n    caf\\351\n..\n", 'names are spelled by to_fs');
