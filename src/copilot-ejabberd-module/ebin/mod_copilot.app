{application, mod_copilot,
 [{description, "CernVM Co-Pilot module for ejabberd"},
  {vsn, "0.0.1"},
  {modules, [mod_copilot]},
  {registered, []},
  {applications, [kernel, stdlib, mongodb]},
  {mod, {mod_copilot, []}}
 ]}.
