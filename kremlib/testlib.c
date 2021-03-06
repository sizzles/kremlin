#include "testlib.h"

void print_buf(uint8_t *buf, size_t size, char *file, int line) {
  char *str = malloc(2 * size + 1);
  for (int i = 0; i < size; ++i)
    sprintf(str + 2 * i, "%02x", buf[i]);
  str[2 * size] = '\0';
  printf("%s:%d: %s\n", file, line, str);
}

void TestLib_compare_and_print(const char *txt, uint8_t *reference,
                               uint8_t *output, int size) {
  char *str = malloc(2 * size + 1);
  char *str_ref = malloc(2 * size + 1);
  for (int i = 0; i < size; ++i) {
    sprintf(str + 2 * i, "%02x", output[i]);
    sprintf(str_ref + 2 * i, "%02x", reference[i]);
  }
  str[2 * size] = '\0';
  str_ref[2 * size] = '\0';
  printf("[test] expected output %s is %s\n", txt, str_ref);
  printf("[test] computed output %s is %s\n", txt, str);

  for (int i = 0; i < size; ++i) {
    if (output[i] != reference[i]) {
      fprintf(stderr, "[test] reference %s and expected %s differ at byte %d\n",
              txt, txt, i);
      exit(EXIT_FAILURE);
    }
  }

  printf("[test] %s is a success\n", txt);

  free(str);
  free(str_ref);
}

void TestLib_touch(int32_t x) {}

#define MK_CHECK(n)                                                            \
  void TestLib_check##n(int##n##_t x, int##n##_t y) {                          \
    if (x != y) {                                                              \
      printf("Test check failure: %" PRId##n " != %" PRId##n "\n", x, y);      \
      exit(253);                                                               \
    }                                                                          \
  }
MK_CHECK(8)
MK_CHECK(16)
MK_CHECK(32)
MK_CHECK(64)

#define MK_UCHECK(n)                                                           \
  void TestLib_checku##n(uint##n##_t x, uint##n##_t y) {                       \
    if (x != y) {                                                              \
      printf("Test check failure: %" PRIu##n " != %" PRIu##n "\n", x, y);      \
      exit(253);                                                               \
    }                                                                          \
  }
MK_UCHECK(8)
MK_UCHECK(16)
MK_UCHECK(32)
MK_UCHECK(64)

void *TestLib_unsafe_malloc(size_t size) {
  void *memblob = malloc(size);
  if (memblob == NULL) {
    printf(" WARNING : malloc failed in tests !\n");
    exit(EXIT_FAILURE);
  }
  return memblob;
}

void TestLib_print_clock_diff(clock_t t1, clock_t t2) {
  printf("User time: %f\n", ((double)t2 - t1) / CLOCKS_PER_SEC);
}

void TestLib_perr(unsigned int err_code) {
  printf("Got error code %u.\n", err_code);
}

void TestLib_print_cycles_per_round(TestLib_cycles c1, TestLib_cycles c2,
                                    uint32_t rounds) {
  printf("[perf] cpu cycles per round (averaged over %d) is %f\n", rounds,
         (float)(c2 - c1) / rounds);
}
