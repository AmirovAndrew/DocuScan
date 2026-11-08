package com.amirovandrew.docuscan.core

import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

/** A 2D point / vector in image coordinates (x to the right, y down). */
data class Vec2(val x: Double, val y: Double) {
    operator fun plus(other: Vec2) = Vec2(x + other.x, y + other.y)
    operator fun minus(other: Vec2) = Vec2(x - other.x, y - other.y)
    operator fun times(k: Double) = Vec2(x * k, y * k)

    fun length(): Double = hypot(x, y)
    fun distanceTo(other: Vec2): Double = hypot(x - other.x, y - other.y)
}

/**
 * A quadrilateral with corners in clockwise order (as seen on screen), starting at the top-left one.
 */
data class Quad(
    val topLeft: Vec2,
    val topRight: Vec2,
    val bottomRight: Vec2,
    val bottomLeft: Vec2,
) {
    val corners: List<Vec2> get() = listOf(topLeft, topRight, bottomRight, bottomLeft)

    fun area(): Double = Geometry.polygonArea(corners)

    fun isConvex(): Boolean = Geometry.isConvex(corners)

    fun map(transform: (Vec2) -> Vec2): Quad =
        Quad(transform(topLeft), transform(topRight), transform(bottomRight), transform(bottomLeft))

    fun scale(sx: Double, sy: Double = sx): Quad = map { Vec2(it.x * sx, it.y * sy) }

    /** Returns a copy with the corner at [index] (0 = top-left, clockwise) replaced. */
    fun withCorner(index: Int, point: Vec2): Quad = when (index) {
        0 -> copy(topLeft = point)
        1 -> copy(topRight = point)
        2 -> copy(bottomRight = point)
        3 -> copy(bottomLeft = point)
        else -> throw IndexOutOfBoundsException("Corner index $index")
    }

    /** Re-sorts the corners so that they are in the canonical clockwise order again. */
    fun normalized(): Quad = Geometry.orderCorners(corners)

    companion object {
        fun fromPoints(points: List<Vec2>): Quad = Geometry.orderCorners(points)

        fun fullFrame(width: Double, height: Double) =
            Quad(Vec2(0.0, 0.0), Vec2(width, 0.0), Vec2(width, height), Vec2(0.0, height))

        /** The whole image in normalized (0..1) coordinates. */
        val UNIT = fullFrame(1.0, 1.0)
    }
}

object Geometry {

    /** Area of a simple polygon (shoelace formula). */
    fun polygonArea(points: List<Vec2>): Double {
        var sum = 0.0
        for (i in points.indices) {
            val a = points[i]
            val b = points[(i + 1) % points.size]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2.0
    }

    /** True if the polygon is strictly convex (all turns go the same way). */
    fun isConvex(points: List<Vec2>): Boolean {
        if (points.size < 3) return false
        var sign = 0
        for (i in points.indices) {
            val a = points[i]
            val b = points[(i + 1) % points.size]
            val c = points[(i + 2) % points.size]
            val cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if (abs(cross) < 1e-9) return false
            val s = if (cross > 0) 1 else -1
            if (sign == 0) sign = s else if (s != sign) return false
        }
        return true
    }

    /**
     * Orders four arbitrary points as top-left, top-right, bottom-right, bottom-left.
     *
     * The points are sorted by angle around their centroid (which gives a clockwise order in image
     * coordinates), then rotated so that the point closest to the image origin comes first.
     */
    fun orderCorners(points: List<Vec2>): Quad {
        require(points.size == 4) { "Expected 4 points, got ${points.size}" }
        val cx = points.sumOf { it.x } / 4.0
        val cy = points.sumOf { it.y } / 4.0
        val sorted = points.sortedBy { atan2(it.y - cy, it.x - cx) }
        val start = sorted.indices.minBy { sorted[it].x + sorted[it].y }
        val o = List(4) { sorted[(start + it) % 4] }
        return Quad(o[0], o[1], o[2], o[3])
    }

    /** Interior angles of a polygon in degrees. */
    fun interiorAngles(points: List<Vec2>): List<Double> = points.indices.map { i ->
        val prev = points[(i + points.size - 1) % points.size]
        val cur = points[i]
        val next = points[(i + 1) % points.size]
        val a = prev - cur
        val b = next - cur
        val denom = a.length() * b.length()
        if (denom == 0.0) {
            0.0
        } else {
            Math.toDegrees(acos(((a.x * b.x + a.y * b.y) / denom).coerceIn(-1.0, 1.0)))
        }
    }
}

/**
 * Works out how large the flattened document should be.
 */
object PerspectiveMath {

    /**
     * Estimates the real width / height ratio of the rectangle that was photographed as [quad].
     *
     * Uses the method from Zhang & He, "Whiteboard scanning and image enhancement" (2007): the
     * camera is modelled as a pinhole with square pixels and its principal point in the centre of
     * the image, the focal length is recovered from the quad itself. When perspective is too weak to
     * estimate the focal length reliably a typical phone-camera focal length is assumed instead
     * (with weak perspective the result barely depends on it anyway).
     *
     * @return the aspect ratio, or null if the quad is degenerate.
     */
    fun estimateAspectRatio(quad: Quad, imageWidth: Double, imageHeight: Double): Double? {
        val cx = imageWidth / 2.0
        val cy = imageHeight / 2.0
        // Homogeneous coordinates relative to the principal point.
        val m1 = doubleArrayOf(quad.topLeft.x - cx, quad.topLeft.y - cy, 1.0)
        val m2 = doubleArrayOf(quad.topRight.x - cx, quad.topRight.y - cy, 1.0)
        val m3 = doubleArrayOf(quad.bottomLeft.x - cx, quad.bottomLeft.y - cy, 1.0)
        val m4 = doubleArrayOf(quad.bottomRight.x - cx, quad.bottomRight.y - cy, 1.0)

        val d2 = dot(cross(m2, m4), m3)
        val d3 = dot(cross(m3, m4), m2)
        if (abs(d2) < 1e-9 || abs(d3) < 1e-9) return null
        val k2 = dot(cross(m1, m4), m3) / d2
        val k3 = dot(cross(m1, m4), m2) / d3

        val n2 = DoubleArray(3) { k2 * m2[it] - m1[it] }
        val n3 = DoubleArray(3) { k3 * m3[it] - m1[it] }

        val longSide = max(imageWidth, imageHeight)
        val defaultF = DEFAULT_FOCAL_FACTOR * longSide
        var f2 = defaultF * defaultF
        val denom = n2[2] * n3[2]
        if (abs(denom) > 1e-12) {
            val estimated = -(n2[0] * n3[0] + n2[1] * n3[1]) / denom
            if (estimated.isFinite() && estimated > 0) {
                val f = kotlin.math.sqrt(estimated)
                if (f in (MIN_FOCAL_FACTOR * longSide)..(MAX_FOCAL_FACTOR * longSide)) f2 = estimated
            }
        }

        val num = n2[0] * n2[0] + n2[1] * n2[1] + f2 * n2[2] * n2[2]
        val den = n3[0] * n3[0] + n3[1] * n3[1] + f2 * n3[2] * n3[2]
        if (den <= 0 || num <= 0) return null
        val ratio = kotlin.math.sqrt(num / den)
        return ratio.takeIf { it.isFinite() && it in 0.05..20.0 }
    }

    /**
     * Size (width, height) of the rectangle [quad] should be flattened into.
     *
     * The measured side lengths are kept for the less foreshortened direction and the other one is
     * stretched to match the estimated real aspect ratio, so no detail is thrown away.
     */
    fun targetSize(quad: Quad, imageWidth: Double, imageHeight: Double, maxSide: Int): Pair<Int, Int> {
        val measuredW = max(quad.topLeft.distanceTo(quad.topRight), quad.bottomLeft.distanceTo(quad.bottomRight))
        val measuredH = max(quad.topLeft.distanceTo(quad.bottomLeft), quad.topRight.distanceTo(quad.bottomRight))
        if (measuredW < 1 || measuredH < 1) return 1 to 1

        val ratio = estimateAspectRatio(quad, imageWidth, imageHeight)
            // Sanity check: an estimate wildly different from the measured shape is not trusted.
            ?.takeIf { it / (measuredW / measuredH) in 0.4..2.5 }
            ?: (measuredW / measuredH)

        var w: Double
        var h: Double
        if (measuredW / measuredH >= ratio) {
            w = measuredW
            h = measuredW / ratio
        } else {
            h = measuredH
            w = measuredH * ratio
        }
        val longest = max(w, h)
        if (longest > maxSide) {
            val k = maxSide / longest
            w *= k
            h *= k
        }
        return w.roundToInt().coerceAtLeast(1) to h.roundToInt().coerceAtLeast(1)
    }

    /** Focal length of a typical phone main camera (~26 mm equivalent) relative to the long side. */
    private const val DEFAULT_FOCAL_FACTOR = 0.75
    private const val MIN_FOCAL_FACTOR = 0.3
    private const val MAX_FOCAL_FACTOR = 5.0

    private fun cross(a: DoubleArray, b: DoubleArray) = doubleArrayOf(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )

    private fun dot(a: DoubleArray, b: DoubleArray) = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
