package com.asahicantu.phonetuner;

// Runs inside a Shizuku "user service" process with shell (adb) privileges.
interface IShellService {
    // Reserved transaction code Shizuku uses to stop the service.
    void destroy() = 16777114;

    // Runs `sh -c command`. Returns "<exitCode>\n<stdout+stderr>".
    String exec(String command) = 1;
}
