for _,f in ipairs(arg) do
  local fn,err=loadfile(f)
  print(f, fn and "OK" or ("SYNTAX ERROR: "..err))
end
