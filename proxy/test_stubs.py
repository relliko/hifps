"""Builds the stub modules (build.py gfx walls) and runs each one's harness (<name>_harness.c) against the
exact bytes. `python test_stubs.py gfx` runs one. 32-bit MSVC, no CRT, no Windows SDK: the
kernel32/user32 import libraries come from stub DLLs built in a temporary folder (their .def exports
the plain names, so the decorated stdcall symbols import those)."""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
VC = r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars32.bat'
MODULES = ['gfx', 'walls']
# dll, { function: stdcall argument count, or None for cdecl varargs }
STUBS = {
    'k32': ('kernel32.dll', {'VirtualAlloc': 4, 'CreateFileA': 7, 'ReadFile': 5, 'GetStdHandle': 1, 'WriteFile': 5,
                             'ExitProcess': 1}),
    'u32': ('user32.dll', {'wsprintfA': None}),
}


def stub_source(funcs):
    lines = []
    for fn, n in funcs.items():
        if n is None:
            lines.append('int __cdecl %s(char *b, const char *f, ...) { return 0; }' % fn)
        else:
            lines.append('void *__stdcall %s(%s) { return 0; }' % (fn, ', '.join('void *a%d' % i for i in range(n))))
    return '\n'.join(lines) + '\n'


def main():
    names = sys.argv[1:] or MODULES
    subprocess.run([sys.executable, os.path.join(HERE, 'build.py')] + names, check=True)
    tmp = tempfile.mkdtemp(prefix='hifps_stubs_')
    failed = False
    try:
        steps = []
        for name, (dll, funcs) in STUBS.items():
            with open(os.path.join(tmp, name + '.def'), 'w') as f:
                f.write('LIBRARY %s\nEXPORTS\n%s\n' % (dll, '\n'.join(funcs)))
            with open(os.path.join(tmp, name + '.c'), 'w') as f:
                f.write(stub_source(funcs))
            steps.append(f'cl /nologo /c /GS- {name}.c >nul'
                         f' && link /nologo /dll /noentry /nodefaultlib /def:{name}.def /out:{name}.dll /implib:{name}.lib {name}.obj >nul')
        for name in names:
            shutil.copy(os.path.join(HERE, name + '_harness.c'), tmp)
            shutil.copy(os.path.join(HERE, name + '.blob'), tmp)
            steps.append(f'cl /nologo /O1 /GS- /c {name}_harness.c'
                         f' && link /nologo /subsystem:console /entry:main /nodefaultlib {name}_harness.obj k32.lib u32.lib')
        cmd = f'"{VC}" >nul 2>&1 && cd /d "{tmp}" && ' + ' && '.join(steps)
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(r.stdout + r.stderr)
        for name in names:
            # Run by full path: cmd here may not search the current folder.
            r = subprocess.run([os.path.join(tmp, name + '_harness.exe')], cwd=tmp, capture_output=True, text=True)
            print('== %s\n%s' % (name, (r.stdout + r.stderr).rstrip()))
            failed = failed or r.returncode != 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
