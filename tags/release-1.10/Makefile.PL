# Makefile.PL for XMLSQL
use ExtUtils::MakeMaker;

WriteMakefile(
	NAME            => 'xmlsql',
	VERSION 	=> '1.10',
	PM	=>	{
		'lib/XMLSQL.pm' => '$(INST_LIBDIR)/XMLSQL.pm',
	},
	PREREQ_PM =>	{
		'DBI' => 1.40,
		'POSIX' => 0,
		'XML::Writer' => 0.4,
		'XML::Writer::String' => 0.1,

	},
	dist => {
		COMPRESS => 'gzip --best'
	},
);

