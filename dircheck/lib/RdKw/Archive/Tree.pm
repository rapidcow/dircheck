package RdKw::Archive::Tree;

use 5.008;
use strict;
use warnings;

use version;
our $VERSION = '0.00_00';
$VERSION = version->parse( $VERSION );

1;
__END__

=head1 NAME

Archive::Tree - directory tree specification compiler

=head1 SYNOPSIS

    use RdKw::Archive::Tree;
    print "$RdKw::Archive::Tree::VERSION\n";

=head1 DESCRIPTION

Reads the dircheck dialect of L<mtree(5)> (see F<draft.txt> in the
source distribution).  This version only holds the version number of
the distribution; the reader is not written yet.

=head1 SEE ALSO

L<dircheck>, L<RdKw::I18N::CodeSets>, L<mtree(5)>

=head1 LICENSE

GNU General Public License, version 3.

=cut
