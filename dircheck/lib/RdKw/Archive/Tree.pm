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

    use RdKw::Archive::Tree::Reader;
    use RdKw::Archive::Tree::MTree;

    my @entries = RdKw::Archive::Tree::Reader->new(file => $name)
        ->parse($text);
    print RdKw::Archive::Tree::MTree->new->format(@entries);

=head1 DESCRIPTION

A specification lists the files of a directory tree, one node to a
line, as L<mtree(5)> does.  L<dircheck> compiles it to L<mtree(5)>,
and L<mtree(8)> checks a tree against that.  This page describes the
specification.  The file is UTF-8.

    #(set type file uid 501 gid 20 mode #o644)
    index.html  digest.sha256 #"\B{47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU}"
    "caf\x{e9}"  time "2026-11-20T06:19:30-06:00"
    src         type tree mode #o755
       "very-long-name" \
          ; a comment line inside a node
          mode #o600
       #(node "link" type link link "../index.html")
    ..

=head2 Lines

C<;> starts a comment, to the end of the line.  A line that starts
with C<#(> is a directive (L</Directives>).  Any other line that is
not blank is a node: its first token is a file name in the current
directory, and the rest are I<key> I<value> pairs.  A node ends at
the end of its line, unless the line ends with C<\> (and maybe a
comment).  Then the node goes on at the next line that is not blank
or only a comment.

=head2 Names

A file name is a bare word, taken as it is written (C<404.html> is
not a number), or a string C<"..."> with escapes.  A bare name cannot
start with C<#>.  A byte string, an empty name, and a name with C</>
or NUL are errors.  The bare words C<.> and C<..> are special: C<..>
leaves the current directory, and C<.> gives keys to the top
directory, if it is the first node.

Names are written to L<mtree(5)> as the file system spells them (as
L<RdKw::I18N::CodeSets/to_fs> says).  A name that cannot be spelled
is an error.

=head2 Values

=over

=item Strings

A bare word (a symbol) and a C<"..."> string are the same: C<type file>
is C<type "file">.  Strings take the escapes of trivnote libexpr:
C<\a \b \t \n \v \f \r \e \s>, C<\N{I<name>}>, C<\cI<X>>,
C<\x41 \101 \o101 \d065 \m1000001>, and braced numbers such as
C<\x{1F 600}>, which are one code point.  Any other character after
C<\> is itself.  C<\> at the end of a line drops the line ending and
the indent after it.

=item Byte strings

C<#"..."> holds ASCII and escapes.  A braced number is octets: up to
two hex digits (three octal or decimal, eight binary) are one octet,
a longer group is split into groups of that size, and C<.> or C<:>
ends a group.  So C<#"\x{c3a9}"> is two octets, and C<"\x{c3a9}"> is
U+C3A9.  C<\B{...}> is base64, where C<-_.> may stand for C<+/=>.

=item Numbers

C<123>, C<1.5>, C<#x1F5>, C<#o755>, C<#b101>, C<#d10>.  A number is
a string of its decimal digits: C<uid #x1F5> is C<uid "501">.
Exponents are not supported.

=item Booleans

C<#t>, C<#true>, C<#f>, C<#false>.

=item Null

C<()> unsets a key.  It is never a value.

=back

=head2 Keys

=over

=item B<type>

C<tree>, C<file> or C<link>.  A C<tree> node opens a directory, which
C<..> closes.

=item B<uid>, B<gid>, B<nlink>, B<size>, B<cksum>

Whole numbers.

=item B<mode>

A whole number up to C<#o7777>.  Write octal with C<#o>: C<mode 0644>
is an error.

=item B<time>

An ISO 8601 string, C<YYYY-MM-DDThh:mm:ss>, with up to nine decimals,
and C<Z> or an offset (C<-06:00>, C<-0600>, C<-06>), not before 1970;
or seconds since the epoch, with up to nine decimals.

=item B<uname>, B<gname>, B<flags>

Strings.

=item B<link>

The target of a C<link> node, which must have one.

=item B<ignore>, B<nochange>, B<optional>

Booleans.

=item B<digest.md5>, B<digest.sha1>, B<digest.rmd160>, B<digest.sha256>, B<digest.sha384>, B<digest.sha512>

Byte strings of the length that the algorithm makes, on C<file>
nodes only.

=back

Other keys are errors.  The L<mtree(5)> names (C<sha256digest>,
C<dir>) are errors that say what to write instead.

=head2 Directives

=over

=item C<#(set> I<key> I<value> ...C<)>

Defaults for the nodes after it in the current directory and the
directories in it.  C<..> forgets the defaults that were set in the
directory it leaves.  A value of C<()> unsets the default.

=item C<#(unset> I<key> ...C<)>

The same as C<#(set> I<key> C<()> ...C<)>.

=item C<#(node> I<name> I<key> I<value> ...C<)>

A node, as a line is.  Line endings inside C<#( )> are spaces, so
C<\> is not needed.

=back

Other directive names are reserved, as are C<[ ] { } |>, C<#|>,
C<#;>, C<#\> and C<#u8>.  Nothing may follow a directive on its line,
but a comment.

=head1 SEE ALSO

L<dircheck>, L<RdKw::Archive::Tree::Reader>,
L<RdKw::Archive::Tree::MTree>, L<RdKw::I18N::CodeSets>, L<mtree(5)>

=head1 LICENSE

GNU General Public License, version 3.

=cut
