
Differences between EtaMOO and LambdaMOO
========================================

Besides the most notable differences described in the README, other minor
differences include:

  * EtaMOO fixes a long-standing bug in LambdaMOO that prevents commands using
    the "off of" preposition from being parsed correctly. To accomplish this,
    the "off/off of" preposition has been changed to "off of/off".

  * Assignment expressions behave somewhat differently in EtaMOO than they do
    in LambdaMOO.

    Assuming `x = {1, 2}` and `y = "foo"`:

| Expression        | LambdaMOO        | EtaMOO           |
| ----------------- | ---------------- | ---------------- |
| `x[1] = x[2] = 3` | `x` => `{3, 2}`  | `x` => `{3, 3}`  |
| `x[1] = (x = 0)`  | `x` => `{0, 2}`  | (error) `E_TYPE` |
| `y[$][1] = "b"`   | (error) `E_TYPE` | `y` => `"fob"`   |

  * EtaMOO provides a visual indication of the point at which MOO code
    compilation failed as part of the list of strings returned by
    `set_verb_code()` and `eval()`.

  * To mirror and complement the native support for string-key association
    list indexing, EtaMOO also extends the `listset()` and `listdelete()`
    functions to accept string-key indices for manipulating well-formed
    association lists.

  * Versions of LambdaMOO up to 1.8.3 only restrict to wizards the *reading*
    of built-in properties protected by `$server_options.protect_`*`prop`*.
    EtaMOO, as well as more recent versions of LambdaMOO, also restrict
    *writing* to such protected properties.

  * EtaMOO doesn't currently check the validity of built-in function names
    when compiling verb code; instead, calling an unknown function raises an
    error at runtime. (This is subject to change.)

  * In both EtaMOO and LambdaMOO, the `crypt()` built-in is a thin wrapper
    around the host system's `crypt()` library function. LambdaMOO doesn't
    check the return value from this function to see if it failed; it ends up
    returning an empty string in this case. EtaMOO raises `E_INVARG` instead.
    Note that `crypt()` can fail if an unsupported salt parameter is used.

  * The `value_hash()`, `string_hash()`, and `binary_hash()` built-in
    functions in EtaMOO accept two optional arguments in addition to the value
    or string to be hashed. The second argument is a string which selects the
    particular hash algorithm to use, and defaults to "MD5". The following
    algorithms are supported:

        MD2
        MD4
        MD5
        RIPEMD-160
        SHA-1
        SHA-224
        SHA-256
        SHA-384
        SHA-512
        SHA-512/224
        SHA-512/256
        SHA3-224
        SHA3-256
        SHA3-384
        SHA3-512
        Skein-256-224
        Skein-256-256
        Skein-512-224
        Skein-512-256
        Skein-512-384
        Skein-512-512
        Tiger
        Whirlpool

    The third argument, if provided and true, causes the digest value to be
    returned as a binary string instead of a string of hexadecimal digits.

  * In LambdaMOO, the `buffered_output_length()` built-in returns the number
    of *bytes* currently buffered for output to a connection. In EtaMOO, this
    built-in currently returns the number of *items* buffered, where an item
    essentially represents all the data from a single call to `notify()`.
    (This is subject to change.)

  * The result of the `disassemble()` built-in is very different in EtaMOO
    than in LambdaMOO, and currently shows the internal abstract syntax tree
    associated with a verb. (This is subject to change.)

  * The effective range of object values in EtaMOO is system-dependent, and
    not necessarily the same as the range of integer values.

