// Just a wrapper around the generated Web Assembly
let buf = readbuffer("Wasm1.wasm");
print("read Wasm1.js");
WebAssembly.instantiate(buf, { js: {} }).then(({ module, instance }) => {
  print("instantiated");
  print("fact(5) is " + instance.exports.Wasm1_fact(5));
  print("minus(5, 4) is " + instance.exports.Wasm1_minus(5, 4));
}, (e) => {
  print(e);
});
