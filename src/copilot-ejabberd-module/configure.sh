#!/bin/bash
LOC=`pwd`
EJD_DIR=$EJD_DIR
ERL_DIR=`echo "code:lib_dir()." | erl | grep "1>" | cut -d '"' -f2`

if [ ! -e "$EJD_DIR" ]; then
	EJD_DIR=/lib/ejabberd
fi

cat > Makefile << EOF
REBAR ?= \$(shell which rebar 2>/dev/null || which ./rebar)
REBAR_FLAGS ?=

all: compile

compile:
	\$(REBAR) compile \$(REBAR_FLAGS)

install: compile
	mkdir $ERL_DIR/egeoip-master
	cp -R deps/egeoip/{ebin,include,priv} $ERL_DIR/egeoip-master

	mkdir $ERL_DIR/mongodb-master
	cp -R deps/mongodb/{ebin,deps,include} $ERL_DIR/mongodb-master

	cp -R ebin/*.beam $EJD_DIR/include

build-deps:
	\$(REBAR) get-deps \$(REBAR_FLAGS)
	cd deps/egeoip && make
	cd deps/mongodb && make

doc:
	\$(REBAR) doc \$(REBAR_FLAGS)

test: compile
	\$(REBAR) eunit \$(REBAR_FLAGS)

clean:
	\$(REBAR) clean \$(REBAR_FLAGS)

clean_plt:
	@rm -f _test/dialyzer_plt

build_plt: build-plt

build-plt:
	@ [ -d _test ] || mkdir _test
	\$(REBAR) build-plt \$(REBAR_FLAGS)

dialyzer:
	\$(REBAR) dialyze \$(REBAR_FLAGS)
EOF

cat > rebar.config << EOF
{deps, [
        {mongodb, ".*", {git, "http://github.com/mongodb/mongodb-erlang.git", "HEAD"}},
        {egeoip, ".*", {git, "http://github.com/mochi/egeoip.git", "HEAD"}}
       ]}.
{lib_dirs, ["deps"]}.
{erl_opts, [debug_info,
            fail_on_warning,
            {i, "$EJD_DIR/include"}
           ]}.
{clean_files, ["ebin/*.beam", "erl_crash.dump"]}.
EOF
