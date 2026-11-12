libnode = {
        version = "22.23.4",
        sha256 = "4dd79de8cdc85d65cb32f48a75aee1067bf00bf94b96ecc8e4c2f82f6f0272c2",
}

local windows = os.host() == "windows"
local root = _MAIN_SCRIPT_DIR
local tarball = path.join(root, ("node-v%s.tar.gz"):format(libnode.version))
local src = path.join(root, ("node-v%s"):format(libnode.version))
local output = path.join(root, "build")

local function native(p)
        return windows and path.translate(p, "\\") or p
end

local function run(command)
        print(("> %s"):format(command))
        if os.execute(command) ~= true then
                error(("failed: %s"):format(command), 0)
        end
end

local function sha256(file)
        local out = windows and os.outputof(('certutil -hashfile "%s" SHA256'):format(native(file))) or os.outputof(('sha256sum "%s"'):format(file))
        return (out or ""):gsub(" ", ""):lower():match(("%x"):rep(64))
end

local function find(dirs, name)
        for _, dir in ipairs(dirs) do
                local file = path.join(src, dir, name)
                if os.isfile(file) then
                        return file
                end
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
        run(('%s "%s" "%s"'):format(windows and "python" or "python3", native(path.join(root, "patches", "patch.py")), native(src)))
end

local function build()
        if windows then
                run(('cd /d "%s" && vcbuild.bat release x64 dll no-cctest'):format(native(src)))
                return
        end
        local compilers = ""
        if (os.outputof("command -v ccache") or "") ~= "" then
                compilers = "CC='ccache gcc' CXX='ccache g++' "
        end
        local jobs = (os.outputof("nproc") or ""):match("%d+") or "4"
        run(('cd "%s" && %s./configure --shared && %smake -j%s'):format(src, compilers, compilers, jobs))
end

local function runtime(dll)
        local imports = os.outputof(('llvm-objdump -p "%s"'):format(native(dll))) or ""
        local vswhere = ("%s\\Microsoft Visual Studio\\Installer\\vswhere.exe"):format(os.getenv("ProgramFiles(x86)"))
        local vs = (os.outputof(('""%s" -latest -property installationPath"'):format(vswhere)) or ""):match("[^\r\n]+")
        if imports == "" or not vs then
                error("can't list libnode22.dll's imports (llvm-objdump) or find Visual Studio (vswhere)", 0)
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
                                error(("libnode22.dll imports %s, which isn't in %s"):format(name, crt), 0)
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
                files = { "libnode22.dll", "libnode22.lib", "libnode22.pdb" }
        else
                files = { "libnode22.so" }
        end
        for _, name in ipairs(files) do
                local file = find({ "out/Release", "out/Release/lib", "out/Release/lib.target" }, name)
                if not os.copyfile(file, path.join(output, name)) then
                        error(("can't copy %s to %s"):format(file, output), 0)
                end
        end
        local library = path.join(output, windows and "libnode22.lib" or "libnode22.so")
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
        for _, name in ipairs({ "uv_default_loop", "uv_loop_init", "uv_loop_close", "uv_run" }) do
                local symbol = (windows and "__imp_%s\n" or " T %s\n"):format(name)
                if not ("%s\n"):format(exported):find(symbol, 1, true) then
                        error(("%s doesn't export %s, which the engine calls"):format(library, name), 0)
                end
                print(("exported: %s"):format(name))
        end
        if windows then
                for _, name in ipairs(runtime(path.join(output, "libnode22.dll"))) do
                        table.insert(files, name)
                end
        end
        for _, name in ipairs(files) do
                local file = path.join(output, name)
                print(("%-24s %12d bytes  sha256 %s"):format(name, io.open(file, "rb"):seek("end"), sha256(file)))
        end
end

newaction {
        trigger = "libnode",
        description = ("Download, change and build Node %s as libnode22 into build/"):format(libnode.version),
        execute = function()
                source()
                build()
                collect()
                os.rmdir(src)
                os.remove(tarball)
        end,
}
