package com.amirovandrew.docuscan.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class GeometryTest {

    private val square = Quad(Vec2(0.0, 0.0), Vec2(10.0, 0.0), Vec2(10.0, 10.0), Vec2(0.0, 10.0))

    @Test
    fun `orders shuffled corners clockwise from top-left`() {
        val shuffled = listOf(square.bottomRight, square.topLeft, square.bottomLeft, square.topRight)
        assertEquals(square, Geometry.orderCorners(shuffled))
    }

    @Test
    fun `orders corners of a slightly rotated page`() {
        val tl = Vec2(110.0, 90.0)
        val tr = Vec2(520.0, 130.0)
        val br = Vec2(480.0, 700.0)
        val bl = Vec2(70.0, 650.0)
        assertEquals(Quad(tl, tr, br, bl), Quad.fromPoints(listOf(br, bl, tr, tl)))
    }

    @Test
    fun `area and convexity`() {
        assertEquals(100.0, square.area(), 1e-9)
        assertTrue(square.isConvex())
        val bowTie = Quad(Vec2(0.0, 0.0), Vec2(10.0, 10.0), Vec2(10.0, 0.0), Vec2(0.0, 10.0))
        assertFalse(bowTie.isConvex())
        // Reordering repairs a crossed quad.
        assertTrue(bowTie.normalized().isConvex())
    }

    @Test
    fun `interior angles of a rectangle are right angles`() {
        Geometry.interiorAngles(square.corners).forEach { assertEquals(90.0, it, 1e-9) }
    }

    @Test
    fun `aspect ratio of a fronto-parallel rectangle is exact`() {
        val quad = Quad(Vec2(100.0, 200.0), Vec2(400.0, 200.0), Vec2(400.0, 400.0), Vec2(100.0, 400.0))
        assertEquals(1.5, PerspectiveMath.estimateAspectRatio(quad, 800.0, 600.0)!!, 1e-6)
    }

    @Test
    fun `recovers the real aspect ratio of a tilted A4 page`() {
        val a4 = 210.0 / 297.0
        val cases = listOf(
            Triple(35.0, 15.0, 5.0),
            Triple(-25.0, 20.0, -10.0),
            Triple(10.0, -30.0, 3.0),
            Triple(40.0, 8.0, 0.0),
        )
        // Here perspective in both directions lets the focal length be estimated, so a camera
        // with an unusual focal length is handled too.
        for (focal in listOf(2400.0, 3200.0, 5000.0)) {
            for ((tiltX, tiltY, roll) in cases) {
                val quad = TestScenes.projectRectangle(
                    210.0, 297.0, 4000.0, 3000.0, focal = focal, distance = 450.0 * focal / 3000,
                    tiltX = tiltX, tiltY = tiltY, roll = roll,
                ).normalized()
                val ratio = PerspectiveMath.estimateAspectRatio(quad, 4000.0, 3000.0)!!
                assertEquals("f=$focal tilt $tiltX/$tiltY/$roll", a4, ratio, 0.01)
            }
        }
    }

    @Test
    fun `tilt around a single axis falls back to a typical focal length`() {
        // Opposite sides stay parallel in one direction, so the focal length can't be recovered
        // from the image; a typical phone camera (f = 0.75 * long side) is assumed.
        val a4 = 210.0 / 297.0
        for ((focal, tolerance) in listOf(3000.0 to 0.005, 2700.0 to 0.03, 3400.0 to 0.03)) {
            val quad = TestScenes.projectRectangle(
                210.0, 297.0, 4000.0, 3000.0, focal = focal, distance = 450.0 * focal / 3000,
                tiltX = 30.0, tiltY = 0.0, roll = 0.0,
            ).normalized()
            val ratio = PerspectiveMath.estimateAspectRatio(quad, 4000.0, 3000.0)!!
            assertEquals("f=$focal", a4, ratio, tolerance)
        }
    }

    @Test
    fun `target size undoes foreshortening`() {
        // Page tilted away from the camera: the projected height is much shorter than it should be.
        val quad = TestScenes.projectRectangle(
            210.0, 297.0, 4000.0, 3000.0, focal = 3000.0, distance = 500.0,
            tiltX = 40.0, tiltY = 0.0, roll = 0.0,
        ).normalized()
        val measuredRatio = quad.topLeft.distanceTo(quad.topRight) / quad.topLeft.distanceTo(quad.bottomLeft)
        assertTrue("projection should look squashed", abs(measuredRatio - 210.0 / 297.0) > 0.1)
        val (w, h) = PerspectiveMath.targetSize(quad, 4000.0, 3000.0, 6000)
        assertEquals(210.0 / 297.0, w.toDouble() / h, 0.01)
    }

    @Test
    fun `target size respects the maximum side`() {
        val quad = Quad.fullFrame(9000.0, 3000.0)
        val (w, h) = PerspectiveMath.targetSize(quad, 9000.0, 3000.0, 3000)
        assertEquals(3000, w)
        assertEquals(1000, h)
    }

    @Test
    fun `degenerate quad has no aspect ratio`() {
        val p = Vec2(5.0, 5.0)
        assertNull(PerspectiveMath.estimateAspectRatio(Quad(p, p, p, p), 100.0, 100.0))
    }
}
