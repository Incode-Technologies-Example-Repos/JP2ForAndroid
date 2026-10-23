package com.incode.jp2.test;

import android.graphics.Bitmap;
import android.graphics.Color;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import com.incode.jp2.JP2Decoder;
import com.incode.jp2.JP2Encoder;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.Arrays;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;

@RunWith(AndroidJUnit4.class)
public class TestDecoderCoexistence {
    @Test
    public void testBothDecodersPreservePixels() throws Exception {
        String loadOrder = InstrumentationRegistry.getArguments().getString("decoderLoadOrder", "incodeFirst");
        String firstDecoder = "originalFirst".equals(loadOrder) ? "com.gemalto.jp2.JP2Decoder" : "com.incode.jp2.JP2Decoder";
        String secondDecoder = "originalFirst".equals(loadOrder) ? "com.incode.jp2.JP2Decoder" : "com.gemalto.jp2.JP2Decoder";
        Class.forName(firstDecoder);
        Class.forName(secondDecoder);
        Bitmap expected = createBitmap();

        try {
            for (int format : new int[]{JP2Encoder.FORMAT_JP2, JP2Encoder.FORMAT_J2K}) {
                byte[] incodeData = new JP2Encoder(expected).setOutputFormat(format).encode();
                byte[] originalData = new com.gemalto.jp2.JP2Encoder(expected).setOutputFormat(format).encode();
                assertNotNull(incodeData);
                assertNotNull(originalData);

                for (byte[] data : new byte[][]{incodeData, originalData}) {
                    assertPixelsEqual(expected, new JP2Decoder(data).decode());
                    assertPixelsEqual(expected, new com.gemalto.jp2.JP2Decoder(data).decode());
                    JP2Decoder.Header header = new JP2Decoder(data).readHeader();
                    assertNotNull(header);
                    assertEquals(expected.getWidth(), header.width);
                    assertEquals(expected.getHeight(), header.height);
                }
            }
        } finally {
            expected.recycle();
        }
    }

    @Test
    public void testTruncatedImageReturnsNull() {
        Bitmap source = createBitmap();
        try {
            byte[] encoded = new JP2Encoder(source).encode();
            assertNotNull(encoded);

            assertNull(new JP2Decoder(Arrays.copyOf(encoded, 12)).decode());
        } finally {
            source.recycle();
        }
    }

    private static Bitmap createBitmap() {
        Bitmap bitmap = Bitmap.createBitmap(32, 16, Bitmap.Config.ARGB_8888);
        bitmap.setHasAlpha(false);
        for (int row = 0; row < bitmap.getHeight(); row++) {
            for (int column = 0; column < bitmap.getWidth(); column++) {
                bitmap.setPixel(column, row, Color.rgb(column * 7, row * 13, (column + row) * 5));
            }
        }
        return bitmap;
    }

    private static void assertPixelsEqual(Bitmap expected, Bitmap actual) {
        assertNotNull(actual);
        try {
            assertEquals(expected.getWidth(), actual.getWidth());
            assertEquals(expected.getHeight(), actual.getHeight());
            for (int row = 0; row < expected.getHeight(); row++) {
                for (int column = 0; column < expected.getWidth(); column++) {
                    assertEquals(expected.getPixel(column, row), actual.getPixel(column, row));
                }
            }
        } finally {
            actual.recycle();
        }
    }
}
