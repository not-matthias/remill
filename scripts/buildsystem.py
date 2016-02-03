#!/usr/bin/env python
# Copyright 2016 Peter Goodman (peter@trailofbits.com), all rights reserved.

import glob
import hashlib
import os
import subprocess
import sys

MCSEMA_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))

CC = os.path.join(MCSEMA_DIR, "third_party", "bin", "clang")
CXX = os.path.join(MCSEMA_DIR, "third_party", "bin", "clang++")

OS = {
  "darwin": "mac",
  "linux": "linux",
  "linux2": "linux",
  "win32": "win",
}[sys.platform]

SHARED_LIB_EXT = {
  "linux": "so",
  "mac": "dylib",
  "win": "dll",
}[OS]

MCSEMA_SRC_DIR = os.path.join(MCSEMA_DIR, "mcsema")
MCSEMA_BUILD_DIR = os.path.join(MCSEMA_DIR, "build")
MCSEMA_TEST_DIR = os.path.join(MCSEMA_DIR, "tests")
MCSEMA_GEN_DIR = os.path.join(MCSEMA_DIR, "generated")
MCSEMA_INCLUDE_DIR = os.path.join(MCSEMA_DIR, "third_party", "include")
MCSEMA_BIN_DIR = os.path.join(MCSEMA_DIR, "third_party", "bin")
MCSEMA_LIB_DIR = os.path.join(MCSEMA_DIR, "third_party", "lib")

try:
  import concurrent.futures
  POOL = concurrent.futures.ThreadPoolExecutor(max_workers=32)
  TASKS = []

  def Task(func, *args, **kargs):
    global POOL, TASKS
    future = POOL.submit(func, *args, **kargs)
    TASKS.append(future)
    return future

  def FinishAllTasks():
    global TASKS
    for task in TASKS:
      task.result()
    POOL.shutdown()

# Don't have a thread pool available.
except:
  def Task(func, *args, **kargs):
    return func(*args, **kargs)

  def FinishAllTasks():
    pass

CXX_FLAGS = [
  # Enable warnings.
  "-Wall",
  "-Werror",
  "-pedantic",

  # Disable specific warnings.
  "-Wno-nested-anon-types",
  "-Wno-extended-offsetof",
  "-Wno-gnu-anonymous-struct",
  "-Wno-variadic-macros",
  "-Wno-gnu-zero-variadic-macro-arguments",
  "-Wno-error=unused-command-line-argument",
  "-Wno-override-module",
  
  # Features.
  "-fno-omit-frame-pointer",
  "-fno-rtti",
  "-fno-exceptions",
  "-fvisibility-inlines-hidden",
  "-std=gnu++11",

  # Macros.
  '-DMCSEMA_DIR="{}"'.format(MCSEMA_DIR),
  '-DMCSEMA_OS="{}"'.format(OS),
  "-D__STDC_LIMIT_MACROS",
  "-D__STDC_CONSTANT_MACROS",
  "-DGOOGLE_PROTOBUF_NO_RTTI",
  "-DNDEBUG",

  # Includes.
  "-isystem", MCSEMA_INCLUDE_DIR,
  "-I{}".format(MCSEMA_DIR),

  # Output info.
  "-fPIC",
  "-fpie",
  "-g3",
  "-m64",
]


def Command(*args):
  """Executes a command and waits for it to finish. If it fails
  then the command itself is printed out."""
  args = [str(a) for a in args]
  try:
    return subprocess.check_output(args)
  except:
    print "{}\n\n".format(" ".join(args))
    pass


def MakeDirsForFile(file_name):
  """Recursively make directories that lead to a particular
  file name."""
  dir_name = os.path.dirname(file_name)
  while not os.path.exists(dir_name):
    try:
      os.makedirs(dir_name)
    except:
      pass


def FindFiles(files_dir, extension):
  """Find a bunch of files inside of a directory, where all
  the files have the same extension."""
  expr = os.path.join(files_dir, "*.{}".format(extension))
  return list(glob.glob(expr))


class FileFinder(object):
  """Generic file finder class for collecting a bunch of files
  with the same extension from multiple directories."""
  def __init__(self, file_extension):
    self.ext = file_extension
    self.files = set()

  def AddFile(self, file_name):
    self.files.add(file_name)

  def SearchDir(self, files_dir):
    self.files.update(FindFiles(files_dir, self.ext))

  def __iter__(self):
    return iter(self.files)


class FileName(object):
  """File name wrapper. A file name is either a string or a
  Future returning a string."""
  def __init__(self, path):
    self.path = path

  def __str__(self):
    if isinstance(self.path, str) or isinstance(self.path, unicode):
      return os.path.abspath(self.path)
    elif hasattr(self.path, 'result'):
      return os.path.abspath(str(self.path.result()))
    assert False


class _File(object):
  """Generic file abstraction with a method of extracting the
  file location."""
  def __init__(self, path):
    self.path = path

  def Paths(self):
    return [self.path]

  def __str__(self):
    return str(self.path)


class _SourceFile(_File):
  """Source file that will be compiled."""
  # Dictionary for memoizing the compilation of source files.
  CACHE = {}

  def __init__(self, source_path, target_path, extra_args):
    super(_SourceFile, self).__init__(FileName(Task(
      self._Build,
      source_path,
      target_path,
      extra_args)))

  def _Build(self, source_path, target_path, extra_args):
    MakeDirsForFile(target_path)
    args = [CXX]
    
    if "mac" == OS:
      args.append("-stdlib=libc++")

    args.extend(CXX_FLAGS)
    args.extend(extra_args)
    args.extend([
      "-c", source_path,
      "-o", target_path])
    Command(*args)
    return target_path


def SourceFile(path, extra_args=[]):
  """Memoized source file compiler. Names compiled object files
  in terms of the extra args and the path to the source file."""

  path = os.path.abspath(str(path))
  key = hashlib.md5("{}{}".format(path, "".join(extra_args))).hexdigest()
  target_path = os.path.join(os.sep, "tmp", "build", "{}.o".format(key))
  
  if target_path not in _SourceFile.CACHE:
    _SourceFile.CACHE[target_path] = _SourceFile(
      path, target_path, extra_args)
  
  return _SourceFile.CACHE[target_path]


class StaticLibrary(_File):
  """Pre-compiled library within the source/library dirs."""
  SEARCH_PATHS = [MCSEMA_LIB_DIR, MCSEMA_BUILD_DIR]

  def __init__(self, name):
    super(StaticLibrary, self).__init__(self._FindLib(name))

  def _FindLib(self, name):
    abs_path = os.path.abspath(name)
    if os.path.exists(abs_path):
      return abs_path
    for where in self.SEARCH_PATHS:
      for ext in ("o", "bc", "so", "dylib", "a"):
        for prefix in ("lib", ""):
          path = os.path.join(where, "{}{}.{}".format(prefix, name, ext))
          if os.path.exists(path):
            return path
    print "Warning: cannot find object file: {}".format(name)
    return name


class ConfigLibraries(object):
  """Set of libraries returned from a configuration command."""
  def __init__(self, *args):
    self.paths = subprocess.check_output(args).strip().split(" ")

  def Paths(self):
    return self.paths


class LinkerLibrary(object):
  """A library that the linker will figure out how to find."""
  def __init__(self, name, os=None):
    global OS
    self._name = name
    self._include = True
    if os and OS != os:
      self._include = False

  def Paths(self):
    paths = []
    if self._include:
      paths.append("-l{}".format(self._name))
    return paths


class _Target(_File):
  """Generic target that must be compiled."""
  def __init__(self, path, source_files=[], object_files=[], libraries=[]):
    path = os.path.abspath(path)
    MakeDirsForFile(path)
    super(_Target, self).__init__(FileName(Task(
      self._Build,
      path,
      source_files,
      object_files,
      libraries)))

  def _Build(self, path, source_files, object_files, libraries):
    args = [CXX]
    args.extend(CXX_FLAGS)

    if "mac" == OS:
      args.append("-stdlib=libc++")

    args.extend(self.extra_args)
    args.extend([
      "-o",
      path,
      "-L{}".format(MCSEMA_LIB_DIR)])

    if "linux" == OS:
      args.extend([
        "-Wl,-z,now",
        "-Wl,-rpath={}".format(MCSEMA_LIB_DIR),
        "-Wl,-gc-sections",
        "-Wl,-E"])

    elif "mac" == OS:
      args.extend([
        "-Xlinker", "-rpath", "-Xlinker", MCSEMA_LIB_DIR,
        "-Wl,-dead_strip",])

    for src in source_files:
      args.extend(src.Paths())

    for obj in object_files:
      args.extend(obj.Paths())

    for lib in libraries:
      args.extend(lib.Paths())

    Command(*args)
    return path

  def Wait(self):
    [str(p) for p in self.Paths()]


class TargetExecutable(_Target):
  """Represents an individual binary executable file."""
  def __init__(self, *args, **kargs):
    self.extra_args = []
    super(TargetExecutable, self).__init__(*args, **kargs)

  def Execute(self, *args):
    Command(self.path, *args)


class TargetLibrary(_Target):
  """Shared library that must be compiled by the system."""
  def __init__(self, *args, **kargs):
    if "linux" == OS:
      self.extra_args = ["-shared"]
    elif "mac" == OS:
      self.extra_args = [
        "-Wl,-flat_namespace",
        "-Wl,-undefined,suppress",
        "-dynamiclib"]
    super(TargetLibrary, self).__init__(*args, **kargs)
