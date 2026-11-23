package com.dpsk.harness.links

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class LinkFileNameTest {
    @Test fun longShareCodeNameRetainsItsImportRoute() {
        assertEquals("a".repeat(114) + ".dpsk", LinksPlugin.safeName("a".repeat(120) + ".dpsk"))
        assertEquals("a".repeat(114) + ".DSHGO", LinksPlugin.safeName("folder/" + "a".repeat(120) + ".DSHGO"))
    }

    @Test fun shortAndExtensionlessNamesKeepTheirExistingShape() {
        assertEquals("profile.dpsk", LinksPlugin.safeName("folder/profile.dpsk"))
        assertEquals("shared", LinksPlugin.safeName("  "))
        assertEquals("a".repeat(120), LinksPlugin.safeName("a".repeat(130)))
        assertEquals("a".repeat(120), LinksPlugin.safeName("a".repeat(120) + "."))
        assertEquals("a." + "b".repeat(118), LinksPlugin.safeName("a." + "b".repeat(120)))
    }

    @Test fun wholeNameIncludingSuffixFitsUtf8Bytes() {
        assertEquals("a".repeat(120), LinksPlugin.safeName("a".repeat(120) + "." + "界".repeat(90)))
        assertEquals("界".repeat(83) + ".dpsk", LinksPlugin.safeName("界".repeat(120) + ".dpsk"))
        assertEquals("界".repeat(85), LinksPlugin.safeName("界".repeat(100)))
    }

    @Test fun truncationNeverSplitsAValidSurrogatePair() {
        val emoji = "\uD83D\uDE00"
        assertEquals("a".repeat(119), LinksPlugin.safeName("a".repeat(119) + emoji))
        assertEquals("a".repeat(113) + ".dpsk", LinksPlugin.safeName("a".repeat(113) + emoji + ".dpsk"))
        val exact = "a".repeat(112) + emoji + ".dpsk"
        assertEquals(exact, LinksPlugin.safeName(exact))
        assertEquals(emoji.repeat(60), LinksPlugin.safeName(emoji.repeat(100)))
    }

    @Test fun byteBoundedNamesCreateRealCacheFiles() {
        val root = Files.createTempDirectory("link-file-name").toFile()
        try {
            val inputs = listOf("a".repeat(120) + "." + "界".repeat(90), "界".repeat(120) + ".dpsk")
            for (input in inputs) {
                val name = LinksPlugin.safeName(input)
                assertTrue(name.toByteArray(Charsets.UTF_8).size <= 255)
                val file = File(root, name)
                file.writeBytes(byteArrayOf(1, 2, 3))
                assertEquals(3L, file.length())
                assertEquals(name, file.name)
            }
        } finally { root.deleteRecursively() }
    }

}
