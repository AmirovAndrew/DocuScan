package com.amirovandrew.docuscan.core

import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

object OpenCv {
    private val loaded by lazy { nu.pattern.OpenCV.loadLocally() }
    fun load() = loaded
}

/** Builds synthetic photos of documents (RGBA) for tests. */
object TestScenes {

    /** A flat page: paper background with rows of dark "text" blocks. */
    fun page(width: Int, height: Int, paper: Scalar, ink: Scalar = Scalar(30.0, 30.0, 30.0, 255.0)): Mat {
        val page = Mat(height, width, CvType.CV_8UC4, paper)
        val random = Random(42)
        val margin = width / 10
        val lineHeight = height / 40
        var y = height / 10
        while (y < height - height / 10) {
            var x = margin
            while (x < width - margin) {
                val wordWidth = (width / 25) + random.nextInt(width / 12)
                val end = minOf(x + wordWidth, width - margin)
                Imgproc.rectangle(page, Point(x.toDouble(), y.toDouble()), Point(end.toDouble(), (y + lineHeight / 2).toDouble()), ink, -1)
                x = end + width / 50
            }
            y += lineHeight
        }
        return page
    }

    /**
     * Draws [page] into a [width]x[height] scene so that its corners land on [quad].
     *
     * @param shadow darkening (0..1) of a soft shadow the page casts towards the bottom right.
     * @param lighting strength (0..1) of a light falloff from the top-left to the bottom-right corner.
     */
    fun scene(
        width: Int,
        height: Int,
        page: Mat,
        quad: Quad,
        background: Scalar = Scalar(60.0, 55.0, 50.0, 255.0),
        texture: Boolean = false,
        noise: Double = 4.0,
        shadow: Double = 0.0,
        lighting: Double = 0.0,
    ): Mat {
        val scene = Mat(height, width, CvType.CV_8UC4, background)
        if (shadow > 0) {
            val offset = width / 150.0
            val k = 1.0 - shadow
            val dark = Scalar(background.`val`[0] * k, background.`val`[1] * k, background.`val`[2] * k, 255.0)
            val shifted = quad.corners.map { Point(it.x + offset, it.y + offset) }
            Imgproc.fillConvexPoly(scene, MatOfPoint(*shifted.toTypedArray()), dark)
            val blur = (width / 60) or 1
            Imgproc.GaussianBlur(scene, scene, Size(blur.toDouble(), blur.toDouble()), 0.0)
        }
        if (texture) {
            val random = Random(7)
            repeat(120) {
                val y = random.nextInt(height).toDouble()
                val shade = background.`val`[0] + random.nextInt(-25, 25)
                Imgproc.line(
                    scene, Point(0.0, y), Point(width.toDouble(), y + random.nextInt(-40, 40)),
                    Scalar(shade, shade * 0.95, shade * 0.9, 255.0), 1 + random.nextInt(3),
                )
            }
        }
        val from = MatOfPoint2f(
            Point(0.0, 0.0), Point(page.cols().toDouble(), 0.0),
            Point(page.cols().toDouble(), page.rows().toDouble()), Point(0.0, page.rows().toDouble()),
        )
        val to = MatOfPoint2f(*quad.corners.map { Point(it.x, it.y) }.toTypedArray())
        val h = Imgproc.getPerspectiveTransform(from, to)
        Imgproc.warpPerspective(
            page, scene, h, Size(width.toDouble(), height.toDouble()),
            Imgproc.INTER_LINEAR, Core.BORDER_TRANSPARENT,
        )
        Imgproc.GaussianBlur(scene, scene, Size(3.0, 3.0), 0.0)
        if (lighting > 0) {
            val falloff = Mat(height, width, CvType.CV_32FC4)
            val row = FloatArray(width * 4)
            for (y in 0 until height) {
                for (x in 0 until width) {
                    val k = (1.0 - lighting * (x.toDouble() / width + y.toDouble() / height) / 2).toFloat()
                    row[x * 4] = k; row[x * 4 + 1] = k; row[x * 4 + 2] = k; row[x * 4 + 3] = 1f
                }
                falloff.put(y, 0, row)
            }
            val f = Mat()
            scene.convertTo(f, CvType.CV_32FC4)
            Core.multiply(f, falloff, f)
            f.convertTo(scene, CvType.CV_8UC4)
        }
        if (noise > 0) {
            val n = Mat(height, width, CvType.CV_16SC4)
            Core.randn(n, 0.0, noise)
            val scene16 = Mat()
            scene.convertTo(scene16, CvType.CV_16SC4)
            Core.add(scene16, n, scene16)
            scene16.convertTo(scene, CvType.CV_8UC4)
            // keep alpha opaque
            val channels = ArrayList<Mat>()
            Core.split(scene, channels)
            channels[3].setTo(Scalar(255.0))
            Core.merge(channels, scene)
        }
        return scene
    }

    /**
     * Projects a [w]x[h] rectangle lying in the z=0 plane with a pinhole camera.
     *
     * @param tiltX rotation around the x axis (degrees), [tiltY] around y, [roll] around z.
     */
    fun projectRectangle(
        w: Double, h: Double,
        imageWidth: Double, imageHeight: Double,
        focal: Double, distance: Double,
        tiltX: Double, tiltY: Double, roll: Double,
        shiftX: Double = 0.0, shiftY: Double = 0.0,
    ): Quad {
        val ax = Math.toRadians(tiltX)
        val ay = Math.toRadians(tiltY)
        val az = Math.toRadians(roll)
        val rx = arrayOf(doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, cos(ax), -sin(ax)), doubleArrayOf(0.0, sin(ax), cos(ax)))
        val ry = arrayOf(doubleArrayOf(cos(ay), 0.0, sin(ay)), doubleArrayOf(0.0, 1.0, 0.0), doubleArrayOf(-sin(ay), 0.0, cos(ay)))
        val rz = arrayOf(doubleArrayOf(cos(az), -sin(az), 0.0), doubleArrayOf(sin(az), cos(az), 0.0), doubleArrayOf(0.0, 0.0, 1.0))
        val r = mul(rz, mul(ry, rx))
        fun project(x: Double, y: Double): Vec2 {
            val px = r[0][0] * x + r[0][1] * y + shiftX
            val py = r[1][0] * x + r[1][1] * y + shiftY
            val pz = r[2][0] * x + r[2][1] * y + distance
            return Vec2(focal * px / pz + imageWidth / 2, focal * py / pz + imageHeight / 2)
        }
        return Quad(project(-w / 2, -h / 2), project(w / 2, -h / 2), project(w / 2, h / 2), project(-w / 2, h / 2))
    }

    private fun mul(a: Array<DoubleArray>, b: Array<DoubleArray>) = Array(3) { i ->
        DoubleArray(3) { j -> (0 until 3).sumOf { k -> a[i][k] * b[k][j] } }
    }

    /** Mean RGBA colour of a rectangle. */
    fun meanColor(image: Mat, x: Int, y: Int, w: Int, h: Int): DoubleArray {
        val roi = image.submat(y, y + h, x, x + w)
        val mean = Core.mean(roi).`val`
        roi.release()
        return mean
    }
}
