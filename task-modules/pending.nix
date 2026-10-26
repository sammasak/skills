# Placeholder for a task that a later epic #16 slice implements: exits 64 with a
# schema-v1 error so contract tests resolve the name without claiming behaviour.
name: {
  description = "epic #16: not implemented yet";
  exec = "echo '{\"schema_version\":1,\"task\":\"${name}\",\"error\":{\"kind\":\"not_implemented\",\"message\":\"epic #16\"}}'; exit 64";
}
