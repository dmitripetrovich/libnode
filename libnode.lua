libnode = {
        version = "26.13.1",
        sha256 = "60c6cdf11c3e9d5932fccd0eafae77f1152661584e129047684cb8646f228d3e",
        name = "libnode26",
        flags = {
                "--without-npm",
                "--without-inspector",
                "--without-sqlite",
                "--without-amaro",
                "--without-lief",
                "--without-ffi",
                "--with-intl=small-icu",
                "--v8-disable-temporal-support",
        },
}

local windows = os.host() == "windows"
local root = _MAIN_SCRIPT_DIR
local tarball = path.join(root, ("node-v%s.tar.gz"):format(libnode.version))
local src = path.join(root, ("node-v%s"):format(libnode.version))
local output = path.join(root, "build")
local headers = path.join(root, "headers")

local function native(p)
        return windows and path.translate(p, "\\") or p
end

local function run(command)
        print(("> %s"):format(command))
        if os.execute(command) ~= true then error(("failed: %s"):format(command), 0) end
end

local function sha256(file)
        local out = windows and os.outputof(('certutil -hashfile "%s" SHA256'):format(native(file))) or os.outputof(('sha256sum "%s"'):format(file))
        return (out or ""):gsub(" ", ""):lower():match(("%x"):rep(64))
end

local function find(dirs, name)
        for _, dir in ipairs(dirs) do
                local file = path.join(src, dir, name)
                if os.isfile(file) then return file end
        end
        error(("no %s in %s under %s"):format(name, table.concat(dirs, ", "), src), 0)
end

local function source()
        if not os.isfile(tarball) then
                run(('curl -fsSL -o "%s" https://nodejs.org/dist/v%s/node-v%s.tar.gz'):format(native(tarball), libnode.version, libnode.version))
        end
        local got = sha256(tarball)
        if got ~= libnode.sha256 then
                os.remove(tarball)
                error(("node-v%s.tar.gz has SHA-256 %s, not %s (deleted, run again)"):format(libnode.version, tostring(got), libnode.sha256), 0)
        end
        os.rmdir(src)
        local tar = windows and ("%s\\System32\\tar.exe"):format(os.getenv("SystemRoot")) or "tar"
        run(('%s -xzf "%s" -C "%s"'):format(tar, native(tarball), native(root)))
        local patches = os.matchfiles(path.join(root, "patches", "*.patch"))
        table.sort(patches)
        for _, patch in ipairs(patches) do
                run(('git -C "%s" apply --directory="node-v%s" "%s"'):format(native(root), libnode.version, native(patch)))
        end
end

local function build()
        local flags = table.concat(libnode.flags, " ")
        if windows then
                run(('cd /d "%s" && set "config_flags=%s" && vcbuild.bat release x64 dll no-cctest'):format(native(src), flags))
                return
        end
        local jobs = (os.outputof("nproc") or ""):match("%d+") or "4"
        run(('cd "%s" && CC=clang CXX=clang++ ./configure --shared --ninja %s && ninja -C out/Release -j%s %s'):format(src, flags, jobs, libnode.name))
end

local function runtime(dll)
        local imports = os.outputof(('llvm-objdump -p "%s"'):format(native(dll))) or ""
        local vswhere = ("%s\\Microsoft Visual Studio\\Installer\\vswhere.exe"):format(os.getenv("ProgramFiles(x86)"))
        local vs = (os.outputof(('""%s" -latest -property installationPath"'):format(vswhere)) or ""):match("[^\r\n]+")
        if imports == "" or not vs then
                error(("can't list %s.dll's imports (llvm-objdump) or find Visual Studio (vswhere)"):format(libnode.name), 0)
        end
        local folders = {}
        for _, folder in ipairs(os.matchdirs(path.join(vs, "VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT"))) do
                local version = folder:match("MSVC[/\\](%d[%d%.]*)[/\\]")
                if version then
                        table.insert(folders, { version = version, folder = folder })
                end
        end
        table.sort(folders, function(a, b)
                local x, y = {}, {}
                for n in a.version:gmatch("%d+") do table.insert(x, tonumber(n)) end
                for n in b.version:gmatch("%d+") do table.insert(y, tonumber(n)) end
                for i = 1, math.max(#x, #y) do
                        if (x[i] or 0) ~= (y[i] or 0) then return (x[i] or 0) < (y[i] or 0) end
                end
                return false
        end)
        local crt = folders[#folders] and folders[#folders].folder
        if not crt then
                error(("no Visual C++ runtime under %s\\VC\\Redist\\MSVC"):format(vs), 0)
        end
        local copied = {}
        for name in imports:gmatch("DLL Name: ([%w_%.]+)") do
                local lower = name:lower()
                if lower:match("^vcruntime%d") or lower:match("^msvcp%d") or lower:match("^concrt%d") then
                        local file = path.join(crt, lower)
                        if not os.isfile(file) or not os.copyfile(file, path.join(output, lower)) then
                                error(("%s.dll imports %s, which isn't in %s"):format(libnode.name, name, crt), 0)
                        end
                        table.insert(copied, lower)
                end
        end
        print(("Visual C++ runtime from %s: %s"):format(crt, table.concat(copied, ", ")))
        return copied
end

local function collect()
        os.rmdir(output)
        os.mkdir(output)
        local files
        if windows then
                files = { ("%s.dll"):format(libnode.name), ("%s.lib"):format(libnode.name), ("%s.pdb"):format(libnode.name) }
        else
                files = { ("%s.so"):format(libnode.name) }
        end
        for _, name in ipairs(files) do
                local file = find({ "out/Release", "out/Release/lib", "out/Release/lib.target" }, name)
                if not os.copyfile(file, path.join(output, name)) then
                        error(("can't copy %s to %s"):format(file, output), 0)
                end
        end
        local library = path.join(output, ("%s.%s"):format(libnode.name, windows and "lib" or "so"))
        local exported
        if windows then
                exported = os.outputof(('llvm-nm "%s"'):format(native(library))) or ""
        else
                run(('strip --strip-unneeded "%s"'):format(library))
                run(('readelf -d "%s" | grep -E "NEEDED|SONAME"'):format(library))
                exported = os.outputof(('nm -D --defined-only "%s"'):format(library)) or ""
        end
        if exported == "" then
                error(("couldn't list the symbols of %s (%s missing?)"):format(library, windows and "llvm-nm" or "nm"), 0)
        end
        for _, name in ipairs({ "uv_default_loop", "uv_loop_init", "uv_loop_close", "uv_run", "uv_threadpool_set_owner", "uv_threadpool_set_owner_cap" }) do
                local symbol = (windows and "__imp_%s\n" or " T %s\n"):format(name)
                if not ("%s\n"):format(exported):find(symbol, 1, true) then
                        error(("%s doesn't export %s, which the engine calls"):format(library, name), 0)
                end
                print(("exported: %s"):format(name))
        end
        if windows then
                for _, name in ipairs(runtime(path.join(output, ("%s.dll"):format(libnode.name)))) do
                        table.insert(files, name)
                end
        else
                os.rmdir(headers)
                run(('cd "%s" && python3 tools/install.py install --headers-only --dest-dir "%s" --prefix / --silent'):format(src, headers))
                for _, folder in ipairs(os.matchdirs(path.join(headers, "include/node/openssl/archs/*"))) do
                        if path.getname(folder) ~= "linux-x86_64" then
                                os.rmdir(folder)
                        end
                end
                local archive = ("%s-include.tar.gz"):format(libnode.name)
                run(('tar -C "%s" --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -cf - include | gzip -9n > "%s"'):format(headers, path.join(output, archive)))
                os.rmdir(headers)
                table.insert(files, archive)
        end
        for _, name in ipairs(files) do
                local file = path.join(output, name)
                print(("%-24s %12d bytes  sha256 %s"):format(name, io.open(file, "rb"):seek("end"), sha256(file)))
        end
end

newaction {
        trigger = "libnode",
        description = "build",
        execute = function()
                source()
                build()
                collect()
                os.rmdir(src)
                os.remove(tarball)
        end,
}

local edit = path.join(root, "edit")
local patchdir = path.join(root, "patches")

newoption {
        trigger = "patch",
        description = "patch",
        value = "name",
}

local function git(args)
        return ('git -C "%s" -c core.autocrlf=false -c core.safecrlf=false -c user.name=libnode -c user.email=libnode@localhost %s'):format(edit, args)
end

local function capture(command)
        local file = os.tmpname()
        if os.execute(('%s > "%s"'):format(command, file)) ~= true then
                os.remove(file)
                error(("failed: %s"):format(command), 0)
        end
        local handle = io.open(file, "rb")
        local text = handle:read("*a")
        handle:close()
        os.remove(file)
        return text
end

local function lines(text)
        local out = {}
        for line in (("%s\n"):format(text)):gmatch("(.-)\n") do
                table.insert(out, line)
        end
        if text:sub(-1) == "\n" then
                table.remove(out)
        end
        return out
end

local function comments(old)
        local pure, inside = {}, false
        for i, line in ipairs(old) do
                local s = line:match("^%s*(.-)%s*$")
                pure[i] = inside or s:sub(1, 2) == "//" or s:sub(1, 2) == "/*"
                local open = line:find("/*", 1, true)
                local slash = line:find("//", 1, true)
                if open and slash and slash < open then open = nil end
                if inside then
                        inside = line:find("*/", 1, true) == nil
                elseif open then
                        inside = line:find("*/", open + 2, true) == nil
                end
        end
        return pure
end

local function commented(old, pure, i)
        local line = old[i]
        return pure[i] or line:find("//", 1, true) ~= nil or line:find("/*", 1, true) ~= nil or line:find("*/", 1, true) ~= nil
end

local function hunks(diff)
        local out, current = {}, nil
        for _, line in ipairs(lines(diff)) do
                local a, b, c, d = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
                if a then
                        b = b == "" and 1 or tonumber(b)
                        a = tonumber(a)
                        current = { first = b == 0 and a + 1 or a, count = b, old = {}, new = {} }
                        table.insert(out, current)
                elseif current and line:sub(1, 1) == "-" then
                        table.insert(current.old, line:sub(2))
                elseif current and line:sub(1, 1) == "+" then
                        table.insert(current.new, line:sub(2))
                end
        end
        return out
end

local function render(file, old, changes)
        local pure = comments(old)
        for _, h in ipairs(changes) do
                if #h.old == 0 then
                        while h.first <= #old and pure[h.first] do
                                h.first = h.first + 1
                        end
                        if h.first <= #old and commented(old, pure, h.first) and h.first > 1 and old[h.first - 1]:match("^%s*$") then
                                h.first = h.first - 1
                        end
                end
        end
        local out = { ("diff --git a/%s b/%s"):format(file, file), ("--- a/%s"):format(file), ("+++ b/%s"):format(file) }
        local delta, done = 0, 1
        for k, h in ipairs(changes) do
                local last = h.first + #h.old - 1
                local limit = changes[k + 1] and changes[k + 1].first or #old + 1
                local lead = 0
                while lead < 3 and h.first - lead - 1 >= done and not commented(old, pure, h.first - lead - 1) do
                        lead = lead + 1
                end
                local trail = 0
                while trail < 3 and last + trail + 1 < limit and not commented(old, pure, last + trail + 1) do
                        trail = trail + 1
                end
                if trail == 0 and last + 1 <= #old then
                        error(("%s: the line after the change at %d is a comment (%s): end the change on a code line"):format(file, last + 1, old[last + 1]), 0)
                end
                local oc, nc = lead + #h.old + trail, lead + #h.new + trail
                local start = h.first - lead
                table.insert(out, ("@@ -%d,%d +%d,%d @@"):format(oc > 0 and start or start - 1, oc, nc > 0 and start + delta or start + delta - 1, nc))
                for i = start, h.first - 1 do table.insert(out, (" %s"):format(old[i])) end
                for _, line in ipairs(h.old) do table.insert(out, ("-%s"):format(line)) end
                for _, line in ipairs(h.new) do table.insert(out, ("+%s"):format(line)) end
                for i = last + 1, last + trail do table.insert(out, (" %s"):format(old[i])) end
                delta = delta + #h.new - #h.old
                done = last + trail + 1
        end
        return out
end

local function commits()
        local list = {}
        for line in capture(git("log --reverse --format=%H:%s base..HEAD")):gmatch("[^\n]+") do
                local hash, name = line:match("^(%x+):(.+)$")
                table.insert(list, { hash = hash, name = name })
        end
        return list
end

local function write(entry)
        local out = {}
        for file in capture(git(("diff --name-only %s~1 %s"):format(entry.hash, entry.hash))):gmatch("[^\n]+") do
                local status = capture(git(("diff --name-status %s~1 %s -- \"%s\""):format(entry.hash, entry.hash, file))):sub(1, 1)
                if status ~= "M" then
                        error(("%s adds or deletes %s: a patch may only change files that exist"):format(entry.name, file), 0)
                end
                local old = lines(capture(git(("show \"%s~1:%s\""):format(entry.hash, file))))
                local diff = capture(git(("diff --no-color --no-ext-diff -U0 %s~1 %s -- \"%s\""):format(entry.hash, entry.hash, file)))
                for _, line in ipairs(render(file, old, hunks(diff))) do
                        table.insert(out, line)
                end
        end
        local handle = io.open(path.join(patchdir, ("%s.patch"):format(entry.name)), "wb")
        handle:write(("%s\n"):format(table.concat(out, "\n")))
        handle:close()
        print(("wrote patches/%s.patch"):format(entry.name))
end

local function prepare(folder)
        if not os.isfile(tarball) then
                run(('curl -fsSL -o "%s" https://nodejs.org/dist/v%s/node-v%s.tar.gz'):format(tarball, libnode.version, libnode.version))
        end
        if sha256(tarball) ~= libnode.sha256 then
                os.remove(tarball)
                error(("node-v%s.tar.gz doesn't match libnode.sha256 (deleted, run again)"):format(libnode.version), 0)
        end
        os.rmdir(folder)
        os.mkdir(folder)
        run(('tar -xzf "%s" -C "%s" --strip-components=1'):format(tarball, folder))
        os.remove(tarball)
end

local function check()
        local folder = path.join(root, "check")
        prepare(folder)
        local relative = path.getrelative(root, folder)
        local patches = os.matchfiles(path.join(patchdir, "*.patch"))
        table.sort(patches)
        local found = 0
        for _, patch in ipairs(patches) do
                if os.execute(('git -C "%s" apply --directory="%s" "%s"'):format(root, relative, patch)) ~= true then
                        os.rmdir(folder)
                        error(("%s doesn't apply to node-v%s"):format(path.getname(patch), libnode.version), 0)
                end
                local handle = io.open(patch, "rb")
                local body = handle:read("*a")
                handle:close()
                for line in body:gmatch("[^\n]+") do
                        local mark = line:sub(1, 1)
                        if (mark == " " or ((mark == "+" or mark == "-") and not line:match("^[+-][+-][+-] "))) and (line:find("//", 1, true) or line:find("/*", 1, true) or line:find("*/", 1, true)) then
                                found = found + 1
                                print(("comment in %s: %s"):format(path.getname(patch), line))
                        end
                end
                print(("applies: %s"):format(path.getname(patch)))
        end
        os.rmdir(folder)
        if found > 0 then
                error(("%d comment lines in the patches"):format(found), 0)
        end
        print(("all %d patches apply to node-v%s"):format(#patches, libnode.version))
end

newaction {
        trigger = "edit",
        description = "edit",
        onStart = function() if windows then error("Something went wrong", 0) end end,
        execute = function()
                prepare(edit)
                run(git("init -q"))
                run(git("add -A"))
                run(git(('commit -q -m "node-v%s"'):format(libnode.version)))
                run(git("tag base"))
                local patches = os.matchfiles(path.join(patchdir, "*.patch"))
                table.sort(patches)
                for _, patch in ipairs(patches) do
                        run(git(('apply "%s"'):format(patch)))
                        run(git("add -A"))
                        run(git(('commit -q -m "%s"'):format(path.getbasename(patch))))
                end
                print(("edit/ has node-v%s with %d patches as commits: change files there, then premake5 save --patch=<name>"):format(libnode.version, #patches))
        end,
}

newaction {
        trigger = "save",
        description = "save",
        onStart = function() if windows then error("Something went wrong", 0) end end,
        execute = function()
                if not os.isdir(path.join(edit, ".git")) then error("no edit/: run premake5 edit first", 0) end
                local changed = capture(git("status --porcelain")) ~= ""
                local name = _OPTIONS["patch"]
                if not name then error(changed and "edit/ has changes: say which patch they belong to with --patch=<name>" or "nothing to save: --patch=<name> rewrites that patch from edit/", 0) end
                if changed then
                        run(git("add -A"))
                        local exists = false
                        for _, entry in ipairs(commits()) do
                                if entry.name == name then exists = true end
                        end
                        if exists then
                                run(git(('commit -q -m "fixup! %s"'):format(name)))
                                run(git("-c sequence.editor=true rebase -q -i --autosquash base"))
                        else
                                run(git(('commit -q -m "%s"'):format(name)))
                        end
                end
                local written = false
                for _, entry in ipairs(commits()) do
                        if entry.name == name then
                                write(entry)
                                written = true
                        end
                end
                if not written then error(("edit/ has no patch named %s"):format(name), 0) end
                check()
                os.rmdir(edit)
        end,
}

newaction {
        trigger = "check",
        description = "check",
        execute = check,
}
