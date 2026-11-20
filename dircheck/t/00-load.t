#!perl
#
# t/00-load.t - basic load

use 5.008;
use strict;
use warnings;
use Test::More tests => 1;

BEGIN {
	use_ok( 'RdKw::Archive::Tree' ) or BAIL_OUT;
}
diag( "Testing RdKw::Archive::Tree $RdKw::Archive::Tree::VERSION, Perl $], $^X" );
