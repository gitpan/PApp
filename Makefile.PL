use ExtUtils::MakeMaker;

use 5.006;

WriteMakefile(
    'dist'	=> {
	            PREOP	=> 'chmod -R u=rwX,go=rX . ;',
	            COMPRESS	=> 'gzip -9v',
	            SUFFIX	=> '.gz',
                    DIST_DEFAULT=> 'predist',
	           },
    'NAME'	=> 'PApp',
    'VERSION_FROM' => 'PApp.pm',
    'LIBS'	=> [''],
    'DEFINE'	=> '',
    'INC'	=> '',
    'PREREQ_PM'	=> {
                    XML::Parser		=> 2.27,
                    #mod_perl		=> 1.21, # not necessarily required anymore
                    Storable		=> 0.60,
                    DBI			=> 1.13,
                    DBD::mysql		=> 2.04,
                    GDBM_File           => 1.03,
                    Compress::LZV1	=> 0.03,
                    String::Similarity	=> 0.01,
                    Crypt::Twofish2	=> 0.01,
		   },
);

sub MY::postamble {
   my $self=shift;
   my $postamble="

# set \$VERSION in all modules
setver:
	\$(PERL) -pi -e 's/^(\\s*\\\$\$VERSION\\s*=\\s*).*\$\$/\$\${1}\$(VERSION);/' *.pm PApp/*.pm

predist: setver
	pod2text PApp.pm >README
	mysqldump -d -B papp >gen-db.sql
	\$(MAKE) tardist

";

   $postamble;
}

