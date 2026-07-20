package org.example.core;

/**
 * A trivial core library so that {@code :app} has a main-scope local project
 * dependency in the monorepo.
 */
public final class Core {

    private Core() {
    }

    public static String greeting() {
        return "Hello from Quarkus REST";
    }
}