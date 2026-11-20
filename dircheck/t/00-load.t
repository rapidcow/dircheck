#!perl
#
# t/00-load.t - basic load

use 5.008;
use strict;
use warnings;
use Test::More tests => 5;

BEGIN {
	use_ok( $_ ) or BAIL_OUT for qw(
		RdKw::Archive::Tree RdKw::Archive::Tree::Reader
		RdKw::Archive::Tree::MTree RdKw::Archive::Ustar RdKw::DVCS::Git::Tar
	);
}
diag( "Testing RdKw::Archive::Tree $RdKw::Archive::Tree::VERSION, Perl $], $^X" );
