use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'PApp::SQL',
    VERSION_FROM => 'SQL.pm',
    'PM'	=> {
    		    'SQL.pm'	=> '$(INST_LIBDIR)/SQL.pm',
                   },
);

