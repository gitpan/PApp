use ExtUtils::MakeMaker;

use 5.006;

use Config;

require "PApp/Config.pm.PL";

WriteMakefile(
    'dist'	=> {
	            PREOP	=> 'chmod -R u=rwX,go=rX . ;',
	            COMPRESS	=> 'gzip -9v',
	            SUFFIX	=> '.gz',
                    DIST_DEFAULT=> 'predist',
	           },
    'NAME'	=> 'PApp',
    'VERSION_FROM' => 'PApp.pm',
    'DIR'	=> [qw(I18n SQL)],
    'LIBS'	=> [''],
    'DEFINE'	=> '',
    'INC'	=> '',
    'EXE_FILES'	=> ['bin/papp-env'],
    'PM'	=> {
    		    'PApp.pm'		=> '$(INST_LIBDIR)/PApp.pm',
    		    'PApp/Apache.pm'	=> '$(INST_LIBDIR)/PApp/Apache.pm',
    		    'PApp/CGI.pm'	=> '$(INST_LIBDIR)/PApp/CGI.pm',
    		    'PApp/Config.pm'	=> '$(INST_LIBDIR)/PApp/Config.pm',
    		    'PApp/Exception.pm'	=> '$(INST_LIBDIR)/PApp/Exception.pm',
    		    'PApp/FormBuffer.pm'=> '$(INST_LIBDIR)/PApp/FormBuffer.pm',
    		    'PApp/HTML.pm'	=> '$(INST_LIBDIR)/PApp/HTML.pm',
    		    'PApp/Parser.pm'	=> '$(INST_LIBDIR)/PApp/Parser.pm',
                   },
    'PREREQ_PM'	=> {
                    XML::Parser		=> 2.27,
                    #mod_perl		=> 1.21, # not necessarily required anymore
                    Storable		=> 0.60,
                    DBI			=> 1.13,
                    DBD::mysql		=> 2.04,
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
	\$(PERL) -pi -e 's/^(\\s*\\\$\$VERSION\\s*=\\s*).*\$\$/\$\${1}\$(VERSION);/' *.pm PApp/*.pm I18n/*.pm SQL/*.pm PApp/Config.pm.PL

predist: setver
	pod2text PApp.pm >README
	#mysqldump -d -B papp >gen-db.sql
	\$(MAKE) tardist

install :: all
	\$(PERL) ./papp-install

";

   $postamble;
}



