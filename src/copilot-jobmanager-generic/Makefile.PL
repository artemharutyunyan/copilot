use ExtUtils::MakeMaker;

WriteMakefile(
               'NAME'         => 'Copilot::Component::JobManager::Generic',
               'VERSION_FROM' => 'lib/Copilot/Component/JobManager/Generic.pm',
               'PREREQ_PM'    => {
                                    'Copilot'                => "0.01",
                                 }
             );

sub MY::postamble 
{
        return <<'MAKE_FRAG';
BINDIR = /usr/bin
SYSCONFDIR=/etc
install-all: install 
	mkdir -p $(DESTDIR)/$(BINDIR)
	mkdir -p $(DESTDIR)/$(SYSCONFDIR)/copilot
	cp -R etc/* $(DESTDIR)/$(SYSCONFDIR)
	cp -R bin/* $(DESTDIR)/$(BINDIR)
	sed -i -e s,COPILOT_CONFIG_DIR_REPLACE,$(SYSCONFDIR)/copilot, $(DESTDIR)/$(BINDIR)/copilot-jobmanager-generic
	sed -i -e s,COPILOT_CONFIG_DIR_REPLACE,$(SYSCONFDIR)/copilot, `find $(DESTDIR)/$(SYSCONFDIR)/copilot -type f`
	rm -rf `find $(DESTDIR)/$(SYSCONFDIR) -name "*.in"`
	@echo "Done"

SEED := $(shell /bin/bash -c "echo $$RANDOM")
TMPDIR = /tmp/$(SEED)
dist-all: dist
	tar zxvf $(DISTVNAME).tar.gz
	rm -rf $(TMPDIR)/$(DISTVNAME)
	rm -rf $(DISTVNAME).tar.gz
	mkdir -p $(TMPDIR)/$(DISTVNAME)
	cp -R etc/ $(TMPDIR)/$(DISTVNAME)
	cp -R bin/ $(TMPDIR)/$(DISTVNAME)
	cp README $(TMPDIR)/$(DISTVNAME)
	rm -rf `find $(TMPDIR)/$(DISTVNAME) -type d -name ".svn"`
	rm -rf $(TMPDIR)/$(DISTVNAME)/etc/keys
	cp -R $(TMPDIR)/$(DISTVNAME)/* $(DISTVNAME)
	tar -cvf  $(DISTVNAME).tar  $(DISTVNAME)
	gzip  $(DISTVNAME).tar
	rm -rf $(DISTVNAME)
	@echo Done
MAKE_FRAG
}
