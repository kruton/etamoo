
Important!
==========

**This is experimental and (currently) incomplete software. It is not yet
fully usable, although with further development it is hoped that it soon will
be.**

_At present, the code will load a database and listen for network
connections. You can connect using `telnet` or your favorite MUD client and
interact with the MOO environment, however no changes to the database will be
saved, and a few other features have also yet to be implemented._

About
=====

EtaMOO is a new implementation of the LambdaMOO server written in Haskell.

[LambdaMOO][] is a network-accessible, multi-user, programmable, interactive
system well-suited to the construction of text-based adventure games,
conferencing systems, and other collaborative software.

  [LambdaMOO]: http://www.ipomoea.org/moo/

EtaMOO differs from LambdaMOO in a few significant ways:

  * EtaMOO is multi-threaded. MOO tasks run concurrently, producing network
    output and changes to the database in isolated transactions that are
    committed only when not in conflict with any other transaction. (In cases
    of conflict, transactions are automatically retried.) Separate threads are
    also used for network connection management, so for example name lookups
    do not block the entire server.

  * EtaMOO is Unicode-aware, and will eventually include support for Unicode
    MOO strings via compile-time build option.

  * EtaMOO supports 64-bit MOO integers via compile-time build option.

  * EtaMOO natively supports string-key association lists with efficient
    lookup and update operations; the list index syntax has been extended to
    allow _`alist`_`[`_`key`_`]` and _`alist`_`[`_`key`_`] = `_`value`_ for
    string *`key`*s whenever *`alist`* is a well-formed association list.

  * EtaMOO supports several additional hashing algorithms besides MD5,
    including SHA-1, SHA-2, SHA-3, and RIPEMD-160, via optional argument to
    `string_hash()`, `binary_hash()`, and `value_hash()`. Hash digests may
    also optionally be returned as binary strings.

  * EtaMOO internally handles binary strings in an efficient manner, and only
    translates to and from the special MOO *binary string* syntax upon demand.
    For example, passing a binary string read from the network directly to
    `decode_binary()` does not suffer a round trip through the *binary string*
    representation.

  * EtaMOO supports fractional second delays in `suspend()` and `fork`.

  * EtaMOO supports IPv6.

The implementation of EtaMOO otherwise closely follows the specifications of
the [LambdaMOO Programmer's Manual][], and should be compatible with most
LambdaMOO databases as of about version 1.8.3 of the LambdaMOO server code.

  [LambdaMOO Programmer's Manual]: http://www.ipomoea.org/moo/#progman

Installing
----------

EtaMOO is built with [Cabal][], the Haskell package manager. In the simplest
case, running:

    cabal install EtaMOO

should automatically download, build, and install the `etamoo` executable
after doing the same for all of its Haskell dependencies.

Cabal itself is part of the [Haskell Platform][] which is available for many
distributions and platforms.

  [Cabal]: http://www.haskell.org/cabal/
  [Haskell Platform]: http://www.haskell.org/platform/

There are a few options you can give to `cabal install` to customize your
build:

| Option                | Feature                                       |
| --------------------- | --------------------------------------------- |
| `-j`                  | Build in parallel using multiple processors   |
| `-f llvm`             | Use GHC's LLVM backend to compile the code    |
| `-f 64bit`            | Enable 64-bit MOO integers                    |

EtaMOO has non-Haskell dependencies on two external libraries: _libpcre_ (with
UTF-8 support enabled) for regular expression matching, and, possibly,
_libcrypt_ (often part of the standard libraries) for the MOO `crypt()`
built-in function. You should ensure you have these available before
installing EtaMOO (e.g. on Debian-derived systems, `sudo apt-get install
libpcre3-dev`).

Hacking
-------

[Documentation][] is available for the various types, data structures, and
functions used internally by EtaMOO.

  [Documentation]: http://verement.github.io/etamoo/doc/

