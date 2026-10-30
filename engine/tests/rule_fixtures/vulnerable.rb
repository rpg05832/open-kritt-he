# Test fixture for security_rules.json. Deliberately vulnerable; never executed.
# "ruleid:" = the next line must be reported, "ok:" = it must not be.
def handle(params, data)
  # ruleid: ruby-dynamic-code
  eval(params[:code])
  # ok: ruby-dynamic-code
  eval("1 + 1")
  # ruleid: ruby-command-interpolation
  system("ping #{params[:host]}")
  # ok: ruby-command-interpolation
  system("uptime")
  # ruleid: ruby-unsafe-yaml
  YAML.load(data)
  # ok: ruby-unsafe-yaml
  YAML.safe_load(data)
end
