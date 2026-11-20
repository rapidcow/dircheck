use 5.008;
use strict;
use warnings;
use ExtUtils::MakeMaker;

my %WriteMakefileArgs = (
	NAME             => 'Archive::Tree',
	AUTHOR           => q{rapidcow},
	VERSION_FROM     => 'lib/RdKw/Archive/Tree.pm',
	ABSTRACT         => q{Directory tree specification (mtree dialect) compiler},
	LICENSE          => 'gpl_3',
	MIN_PERL_VERSION => '5.008',
	CONFIGURE_REQUIRES => {
		'ExtUtils::MakeMaker' => '0',
	},
	TEST_REQUIRES => {
		'Test::More' => '0',
	},
	PREREQ_PM => {
		'version' => '0',
		'Encode' => '0',
		'RdKw::I18N::CodeSets' => '0',
	},
	EXE_FILES => [
		'script/dircheck',
	],
	MAN1PODS => {
		'script/dircheck' => 'blib/man1/dircheck.1',
	},
	dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz' },
	clean => { FILES => 'Archive-Tree-*' },
	test => { TESTS => 't/*.t' },
);

# Compatibility with old versions of ExtUtils::MakeMaker
unless (eval { ExtUtils::MakeMaker->VERSION('6.64'); 1 }) {
    my $test_requires = delete $WriteMakefileArgs{TEST_REQUIRES} || {};
    @{$WriteMakefileArgs{PREREQ_PM}}{keys %$test_requires} = values %$test_requires;
}

unless (eval { ExtUtils::MakeMaker->VERSION('6.55_03'); 1 }) {
    my $build_requires = delete $WriteMakefileArgs{BUILD_REQUIRES} || {};
    @{$WriteMakefileArgs{PREREQ_PM}}{keys %$build_requires} = values %$build_requires;
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
    unless eval { ExtUtils::MakeMaker->VERSION('6.52'); 1 };
delete $WriteMakefileArgs{MIN_PERL_VERSION}
    unless eval { ExtUtils::MakeMaker->VERSION('6.48'); 1 };
delete @WriteMakefileArgs{qw(META_ADD META_MERGE)}
    unless eval { ExtUtils::MakeMaker->VERSION('6.46'); 1 };
delete $WriteMakefileArgs{LICENSE}
    unless eval { ExtUtils::MakeMaker->VERSION('6.31'); 1 };

WriteMakefile(%WriteMakefileArgs);

package MY;

sub postamble
{
	my ($Me) = @_;
	my $command = '$(FULLPERLRUN)';
	<<'MAKE_FRAG' .
EXTRA_TEST_FILES=	xt/*
xtest :: subdirs-test_dynamic
MAKE_FRAG
	$_[0]->test_via_harness($command, '$(EXTRA_TEST_FILES)');
}
