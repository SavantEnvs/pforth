// mayhem/lsan_off.cc -- build-time LeakSanitizer off-switch (SPEC.md section 6.2 item 15).
//
// -fsanitize=address always bundles LeakSanitizer, and leaks are not the memory-safety class this
// target is fuzzed for. mayhem/build.sh compiles this TU with $SANITIZER_FLAGS and links it into
// both /mayhem/pforth_fuzzer and /mayhem/pforth_fuzzer-standalone. It turns off ONLY leak
// detection; ASan's memory-error checks and UBSan stay fully active. It sets no runtime option:
// Mayhem owns the runtime ASan/libFuzzer option set.
extern "C" int __lsan_is_turned_off() { return 1; }
