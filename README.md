KreMLin
-------

## Trying out KreMLin

Make sure you run `opam update` first, so that by running the `opam install`
command below you get `process-0.2.1` (`process` version `0.2` doesn't work on
Windows). Install all of the packages below, on Windows possibly following
instructions from https://github.com/baguette/ocaml-installer/wiki for "difficult"
packages (e.g. `ppx_deriving`).

`$ opam install ppx_deriving_yojson zarith pprint menhir ulex process fix`

To build just run `make` from this directory.

If you have the latest version of F* and `fstar.exe` is in your `PATH` then you
can run the KreMLin test suite by doing `make test`.

File a bug if things don't work!

## Documentation

Check out the `--help` flag:
```
$ _build/src/Kremlin.native --help
```

## License

Kremlin is released under the [Apache 2.0 license]; see `LICENSE` for more details.

[Apache 2.0 license]: https://www.apache.org/licenses/LICENSE-2.0
