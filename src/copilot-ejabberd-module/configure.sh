#!/bin/bash
LOC=`pwd`
EJD_DIR=$EJD_DIR
ERL_DIR=`echo "code:lib_dir()." | erl | grep "1>" | cut -d '"' -f2`

if [ ! -e "$EJD_DIR" ]; then
	EJD_DIR=/lib/ejabberd
fi

echo " - ejabberd: $EJD_DIR"
echo " - Erlang: $ERL_DIR"
echo

echo " * Generating Makefile..."
cat > Makefile << EOF
REBAR ?= \$(shell which rebar 2>/dev/null || which ./rebar)
REBAR_FLAGS ?=

all: build-deps compile

compile:
	erlc -I $EJD_DIR -o ebin src/*.erl

install:
	cp -R ebin/*.beam $EJD_DIR/include

build-deps:
	\$(REBAR) get-deps \$(REBAR_FLAGS)
	cd deps/egeoip && make
	cd deps/mongodb && ./rebar get-deps && make

install-deps: build-deps
	mkdir $ERL_DIR/egeoip-master
	cp -R deps/egeoip/{ebin,include,priv} $ERL_DIR/egeoip-master

	mkdir $ERL_DIR/mongodb-master
	cp -R deps/mongodb/{ebin,deps,include} $ERL_DIR/mongodb-master

clean:
	\$(REBAR) clean \$(REBAR_FLAGS)
EOF

echo " * Generating rebar.config..."
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

echo " * Done. Run 'make' to install the module."
