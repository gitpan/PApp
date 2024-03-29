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
    'DIR'	=> [qw(I18n Recode Storable)],
    'LIBS'	=> [''],
    'DEFINE'	=> '',
    'INC'	=> '',
    'EXE_FILES'	=> [
                    'bin/papp-env',
                    'bin/papp-admin',
                    'bin/papp-httpd',
                    'bin/agni',
                    'xpcse/xpcse',
                    'xpcse/run-mailcap',
                   ],
    'PM'	=> {
		    'PApp.pm'		=> '$(INST_LIBDIR)/PApp.pm',
		    'PApp/Apache.pm'	=> '$(INST_LIBDIR)/PApp/Apache.pm',
		    'PApp/Apache2.pm'	=> '$(INST_LIBDIR)/PApp/Apache2.pm',
		    'PApp/CGI.pm'	=> '$(INST_LIBDIR)/PApp/CGI.pm',
		    'PApp/Env.pm'	=> '$(INST_LIBDIR)/PApp/Env.pm',
		    'PApp/Event.pm'	=> '$(INST_LIBDIR)/PApp/Event.pm',
		    'PApp/DataRef.pm'	=> '$(INST_LIBDIR)/PApp/DataRef.pm',
		    'PApp/Callback.pm'	=> '$(INST_LIBDIR)/PApp/Callback.pm',
		    'PApp/Config.pm'	=> '$(INST_LIBDIR)/PApp/Config.pm',
		    'PApp/Exception.pm'	=> '$(INST_LIBDIR)/PApp/Exception.pm',
		    'PApp/FormBuffer.pm'=> '$(INST_LIBDIR)/PApp/FormBuffer.pm',
		    'PApp/HTML.pm'	=> '$(INST_LIBDIR)/PApp/HTML.pm',
		    'PApp/Log.pm'	=> '$(INST_LIBDIR)/PApp/Log.pm',
		    'PApp/Lock.pm'	=> '$(INST_LIBDIR)/PApp/Lock.pm',
		    'PApp/Application.pm'=> '$(INST_LIBDIR)/PApp/Application.pm',
		    'PApp/ECMAScript.pm'=> '$(INST_LIBDIR)/PApp/ECMAScript.pm',
		    'PApp/Util.pm'	=> '$(INST_LIBDIR)/PApp/Util.pm',
		    'PApp/PCode.pm'	=> '$(INST_LIBDIR)/PApp/PCode.pm',
		    'PApp/XML.pm'	=> '$(INST_LIBDIR)/PApp/XML.pm',
		    'PApp/XSLT.pm'	=> '$(INST_LIBDIR)/PApp/XSLT.pm',
		    'PApp/XSLT/Sablotron.pm'	=> '$(INST_LIBDIR)/PApp/XSLT/Sablotron.pm',
		    'PApp/XSLT/LibXSLT.pm'	=> '$(INST_LIBDIR)/PApp/XSLT/LibXSLT.pm',
		    'PApp/Admin.pm'	=> '$(INST_LIBDIR)/PApp/Admin.pm',
		    'PApp/Prefs.pm'	=> '$(INST_LIBDIR)/PApp/Prefs.pm',
		    'PApp/Session.pm'	=> '$(INST_LIBDIR)/PApp/Session.pm',
		    'PApp/User.pm'	=> '$(INST_LIBDIR)/PApp/User.pm',
		    'PApp/UserObs.pm'	=> '$(INST_LIBDIR)/PApp/UserObs.pm',
		    'PApp/Preprocessor.pm'	=> '$(INST_LIBDIR)/PApp/Preprocessor.pm',
		    'PApp/XBox.pm'	=> '$(INST_LIBDIR)/PApp/XBox.pm',
		    'PApp/MimeType.pm'	=> '$(INST_LIBDIR)/PApp/MimeType.pm',
		    'PApp/XPCSE.pm'	=> '$(INST_LIBDIR)/PApp/XPCSE.pm',
		    'PApp/EditForm.pm'	=> '$(INST_LIBDIR)/PApp/EditForm.pm',
		    'Agni.pm'		=> '$(INST_LIBDIR)/Agni.pm',
                   },
    'PREREQ_PM'	=> {
                    common::sense       => 3.3,

		    PApp::SQL		=> 0.143,
                    Compress::LZF	=> 1.0,
                    String::Similarity	=> 0.02,
                    Convert::Scalar	=> 1.02,
                    Crypt::Twofish2	=> 0.01,

                    URI			=> 1.22,
                    XML::Parser		=> 2.31,
                    Storable		=> 2.05,
                    DBI			=> 1.30,
                    Digest::SHA1	=> 1.01,
                    JSON::XS		=> 2.01,
                    MIME::Base64        => 0,

                    DBD::mysql		=> 2.04,
                    Guard               => 1.0,

                    # the following are more or less optional, but highly useful
                    XML::Sablotron	=> 1.0100001, # http://www.gingerall.com/charlie-bin/get/webGA/act/sablotron.act
                    #mod_perl		=> 1.21, # not necessarily required anymore
                    #CGI::SpeedyCGI	=> 2.21,  # speedycgi uses a broken numbering scheme
                    #XML::LibXSLT	=> 0.0,  # gnome-xml, libxslt
		   },
);

sub MY::postamble {
   my $self=shift;
   my $postamble="

force:

all :: secure

secure :: write-config
	\$(PERL) write-config

reconfig: force
	\$(PERL) write-config

i18n: force
	./bin/papp-admin `for domain in papp bench dbedit demo iso639 iso3166 iso3166full; do \\
	  echo --domain \$\$domain --export i18n/\$\$domain.po; \\
	done`

# set \$VERSION in all modules
setver:
	\$(PERL) -pi -e 's/^(\\s*(?:our\\s+)?\\\$\$VERSION\\s*=\\s*).*\$\$/\$\${1}\$(VERSION);/' *.pm PApp/*.pm I18n/*.pm Recode/*.pm

predist: setver i18n
	pod2text PApp.pm >README
	#mysqldump -d -B papp >gen-db.sql
	\$(MAKE) tardist

install :: secure all
	\$(PERL) ./papp-install --install

install :: secure all
	\@echo
	\@echo '*****'
	\@echo '***** Please run:'
	\@echo '*****'
	\@echo '***** make init		to initialize the papp database'
	\@echo '***** make update	to update an existing papp installation'
	\@echo '*****'
	\@echo

init: secure all
	\$(PERL) ./papp-install --init

update: secure all
	\$(PERL) ./papp-install --update

";

   $postamble;
}

system $Config{make}, "secure";

print <<EOF;

**
** if you want to change your configuration, just type '$Config{make} reconfig'
**

EOF


