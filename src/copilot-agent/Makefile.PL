use ExtUtils::MakeMaker;

WriteMakefile(
               'NAME'      => 'Copilot::Component::Agent',
               'VERSION'   => '0.01',
               'PREREQ_PM' => {
                              	'Copilot' => "0.01",
                              }
             );

sub MY::postamble 
{
	return <<'MAKE_FRAG';
BINDIR = /usr/bin
SYSCONFDIR=/etc
install-all: install 
	mkdir -p $(DESTDIR)/$(PREFIX)/$(BINDIR)
	mkdir -p $(DESTDIR)/$(PREFIX)/$(SYSCONFDIR)/copilot
	cp -R etc/* $(DESTDIR)/$(PREFIX)/$(SYSCONFDIR)
	cp -R bin/* $(DESTDIR)/$(PREFIX)/$(BINDIR)
	sed -i -e s,COPILOT_CONFIG_DIR_REPLACE,$(SYSCONFDIR)/copilot, `find $(DESTDIR)/$(PREFIX)/$(SYSCONFDIR)/copilot -type f`
	rm -rf `find $(DESTDIR)/$(PREFIX)/$(SYSCONFDIR) -name "*.in"`
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
