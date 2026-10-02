#include <stddef.h>

/* Independent byte-level oracle for the runtime's actual process arguments. */
int main(int argc, char **argv)
{
    if (argc < 1 || !argv) return 251;
    if (!argv[0] || !argv[0][0]) return 252;
    if (argv[argc] != NULL) return 253;
    int code = argc;
    for (int argument = 1; argument < argc; ++argument) {
        if (!argv[argument]) return 254;
        const unsigned char *text = (const unsigned char *)argv[argument];
        for (size_t offset = 0; text[offset]; ++offset)
            code = (code * 17 + text[offset]) % 113;
        code = (code + 31) % 113;
    }
    return code;
}
