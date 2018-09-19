import os, osproc, ospaths, json, strutils, tables, strtabs, streams, parseopt, xmltree, xmlparser
type
  CmdLine = object
    cbproj: string
    nimfile: string
    cache: string
    cc: string
    release: bool
    cpu: string
    others: seq[string]

proc errorUsage() =
  quit("Usage: nimcb --proj:filename[.cbproj] [--nimcache:path] [--config:Config] [--platform:Platform] [options] file.nim")
  
proc getCmdLine(): CmdLine =
  result.others = @[]
  var config, platform: string
  var p = initOptParser()
  for kind, key, val in p.getopt():
    proc addOption(res: var CmdLine) = 
      res.others.add((if kind == cmdShortOption: "-" else: "--") & key & (if val != "": ":" & val else: "") )
    case kind
    of cmdArgument:
      if result.nimfile == "": result.nimfile = addFileExt(key, "nim")
      else: errorUsage()
    of cmdLongOption, cmdShortOption:
      case key.normalize
      of "proj": result.cbproj = addFileExt(val, "cbproj")
      of "nimcache": result.cache = val
      of "cc": result.cc = val
      of "config": config = val
      of "platform": platform = val
      of "genscript", "compileonly", "nomain", "header": discard
      of "d": 
        if val == "release" : config = "Release" 
        else: addOption(result)
      else: addOption(result)
    else: assert(false)
  if config == "Release" : result.release = true
  case platform 
    of "Win32": result.cpu = "i386"
    of "Win64": result.cpu = "amd64"
    else: discard
  if result.cache == "": result.cache = "nimcache"
  if result.cc == "": result.cc = "bcc"
  # echo $result
  if result.nimfile == "" or result.cbproj == "": errorUsage()
  if not fileExists(result.cbproj): quit "file: " & result.cbproj & " does not exist"
  if not fileExists(result.nimfile): quit "file: " & result.nimfile & " does not exist"

proc buildArgs(cmd: CmdLine): seq[string] =
  result = @["cpp", "--nimcache:" & cmd.cache, "--cc:" & cmd.cc, "--genScript", "--compileOnly", "--noMain", "--header", "--cppCompileToNamespace"]
  if cmd.release : result.add "-d:release"
  if cmd.cpu != "" : result.add "--cpu:" & cmd.cpu
  for o in cmd.others: result.add o
  result.add cmd.nimfile

  
proc main() =
  var cmd = getCmdLine()
  var args = cmd.buildArgs
  var nimprc = startProcess("nim", args=args, options={poParentStreams, poUsePath})
  if nimprc.waitForExit() != 0: quit "nim compilation failed"

  var s = newFileStream(cmd.cbproj, fmRead)
  if s == nil: quit "cannot open " & cmd.cbproj
  echo "load ", cmd.cbproj
  var root = parseXml(s)
  s.close()
  var (npath, nfile, next) = cmd.nimfile.splitFile
  let jname = cmd.cache / nfile & ".json"
  let js = newFileStream(jname) 
  if js == nil: quit "cannot open " & jname
  var json = parseJson(js, jname)
  var names = initTable[string, string]()
  for e in json["compile"].getElems:
    let info = e.getElems[0].getStr.splitFile
    var name = cmd.cache / info.name & info.ext
    names.add name.toLower, name
  # echo names[0]
  var compNodes: seq[XmlNode] = @[]
  root.findAll("CppCompile", compNodes)
  var changed = false
  for par in root:
    if par.tag == "ItemGroup" :
      var rem: seq[int] = @[]
      var node = 0
      var maxBuildOrder = 0
      for x in par:
        if x.tag == "CppCompile" :
          var iname = x.attr("Include").toLowerAscii 
          if names.hasKey(iname) :
            names.del(iname)
          else:
            var info = iname.splitFile
            if info.dir == cmd.cache.toLowerAscii:
              echo "should remove " & iname
              rem.add node
          var bo = x.child("BuildOrder")
          if bo != nil : 
            let bon = parseInt(bo.innerText)
            if bon > maxBuildOrder: maxBuildOrder = bon
        inc node
      for i in 1.. rem.len:
        # echo rem[^i]
        par.delete(rem[^i])
        changed = true
      for name in names.values:
        inc maxBuildOrder
        par.add <>CppCompile(Include=name,<>BuildOrder(newText($maxBuildOrder)))
        changed = true
  if changed:
    s = newFileStream(cmd.cbproj, fmWrite)
    s.write($root)
    s.close()
  

main()
