use ExtUtils::MakeMaker;

# 5.7. is DEFINITELY required, due to utf8 support
# maybe 5.6.1 will work, once it's out, but I doubt it.
require 5.007;

use Config;

WriteMakefile(
    'dist'	=> {
	            PREOP	=> '(sdf -2txt_pod doc/intro.sdf; rm intro.out) | tee README >$(DISTVNAME)/README; '.
                                   'chown -R root.root .; chmod -R u=rwX,go=rX . ;',
	            COMPRESS	=> 'gzip -9v',
	            SUFFIX	=> '.gz',
                    DIST_DEFAULT=> 'predist',
	           },
    'NAME'	=> 'PApp',
    'VERSION_FROM' => 'PApp.pm',
    'DIR'	=> [qw(I18n Recode)],
    'LIBS'	=> [''],
    'DEFINE'	=> '',
    'INC'	=> '',
    'EXE_FILES'	=> ['bin/papp-env', 'bin/papp-admin'],
    'PM'	=> {
		    'PApp.pm'		=> '$(INST_LIBDIR)/PApp.pm',
		    'PApp/Apache.pm'	=> '$(INST_LIBDIR)/PApp/Apache.pm',
		    'PApp/CGI.pm'	=> '$(INST_LIBDIR)/PApp/CGI.pm',
		    'PApp/Env.pm'	=> '$(INST_LIBDIR)/PApp/Env.pm',
		    'PApp/Event.pm'	=> '$(INST_LIBDIR)/PApp/Event.pm',
		    'PApp/DataRef.pm'	=> '$(INST_LIBDIR)/PApp/DataRef.pm',
		    'PApp/Callback.pm'	=> '$(INST_LIBDIR)/PApp/Callback.pm',
		    'PApp/Config.pm'	=> '$(INST_LIBDIR)/PApp/Config.pm',
		    'PApp/Exception.pm'	=> '$(INST_LIBDIR)/PApp/Exception.pm',
		    'PApp/FormBuffer.pm'=> '$(INST_LIBDIR)/PApp/FormBuffer.pm',
		    'PApp/HTML.pm'	=> '$(INST_LIBDIR)/PApp/HTML.pm',
		    'PApp/Parser.pm'	=> '$(INST_LIBDIR)/PApp/Parser.pm',
		    'PApp/Log.pm'	=> '$(INST_LIBDIR)/PApp/Log.pm',
		    'PApp/Lock.pm'	=> '$(INST_LIBDIR)/PApp/Lock.pm',
		    'PApp/Application.pm'=> '$(INST_LIBDIR)/PApp/Application.pm',
		    'PApp/ECMAScript.pm'=> '$(INST_LIBDIR)/PApp/ECMAScript.pm',
		    'PApp/Util.pm'	=> '$(INST_LIBDIR)/PApp/Util.pm',
		    'PApp/PCode.pm'	=> '$(INST_LIBDIR)/PApp/PCode.pm',
		    'PApp/Package.pm'	=> '$(INST_LIBDIR)/PApp/Package.pm',
		    'PApp/XML.pm'	=> '$(INST_LIBDIR)/PApp/XML.pm',
		    'PApp/XSLT.pm'	=> '$(INST_LIBDIR)/PApp/XSLT.pm',
		    'PApp/XSLT/Sablotron.pm'	=> '$(INST_LIBDIR)/PApp/XSLT/Sablotron.pm',
		    'PApp/XSLT/LibXSLT.pm'	=> '$(INST_LIBDIR)/PApp/XSLT/LibXSLT.pm',
		    'PApp/Admin.pm'	=> '$(INST_LIBDIR)/PApp/Admin.pm',
		    'PApp/Prefs.pm'	=> '$(INST_LIBDIR)/PApp/Prefs.pm',
		    'PApp/User.pm'	=> '$(INST_LIBDIR)/PApp/User.pm',
		    'PApp/UserObs.pm'	=> '$(INST_LIBDIR)/PApp/UserObs.pm',
                   },
    'PREREQ_PM'	=> {
		    PApp::SQL		=> 0.121,
                    Compress::LZF	=> 0.1041,
                    String::Similarity	=> 0.02,
                    Convert::Scalar	=> 0.06,
                    Crypt::Twofish2	=> 0.01,

                    URI			=> 1.12,
                    XML::Parser		=> 2.27,
                    #mod_perl		=> 1.21, # not necessarily required anymore
                    Storable		=> 0.702,
                    DBI			=> 1.13,
                    Digest::SHA1	=> 1.01,

                    DBD::mysql		=> 2.04,
                    CGI::SpeedyCGI	=> 1.8,  # speedycgi uses a broken numbering scheme
                    #XML::Sablotron	=> 0.43, # http://www.gingerall.com/charlie-bin/get/webGA/act/sablotron.act
                    #XML::LibXSLT	=> 0.0,  # gnome-xml, libxslt
		   },
);

sub MY::postamble {
   my $self=shift;
   my $postamble="

force:

all :: config.pl

config.pl :: PApp/Config.pm.PL
	\$(PERL) PApp/Config.pm.PL

reconfig: force
	\$(PERL) PApp/Config.pm.PL

i18n: force
	./bin/papp-admin `for domain in papp bench dbedit demo iso639 iso3166 iso3166full; do \\
	  echo --domain \$\$domain --export i18n/\$\$domain.po; \\
	done`

# set \$VERSION in all modules
setver:
	\$(PERL) -pi -e 's/^(\\s*\\\$\$VERSION\\s*=\\s*).*\$\$/\$\${1}\$(VERSION);/' *.pm PApp/*.pm I18n/*.pm Recode/*.pm PApp/Config.pm.PL

predist: setver i18n
	pod2text PApp.pm >README
	#mysqldump -d -B papp >gen-db.sql
	\$(MAKE) tardist

install :: config.pl all
	\@echo
	\@echo '*****'
	\@echo '***** Please run:'
	\@echo '*****'
	\@echo '***** \$(PERL) papp-install'
	\@echo '*****'
	\@echo '***** now to initialize the papp databases, if necessary.'
	\@echo '*****'
	\@echo

";

   $postamble;
}

system $Config{make}, "config.pl";

print <<EOF;

**
** if you want to change your configuration, just type '$Config{make} reconfig'
**

EOF


