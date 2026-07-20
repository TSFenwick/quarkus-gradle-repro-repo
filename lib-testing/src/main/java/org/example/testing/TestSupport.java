package org.example.testing;

/**
 * A trivial test-support library so that {@code :app} has a test-scope local
 * project dependency in the monorepo.
 */
public final class TestSupport {

    private TestSupport() {
    }

    public static String expectedGreeting() {
        return "Hello from Quarkus REST";
    }
}