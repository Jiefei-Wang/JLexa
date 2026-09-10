package androidx.media3.extractor.mp3;

import static org.junit.jupiter.api.Assertions.*;

import androidx.media3.common.DataReader;
import androidx.media3.common.Format;
import androidx.media3.common.util.ParsableByteArray;
import androidx.media3.extractor.*;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

/** Exercises the real extractor and seek map, without mocking timestamps. */
class IndexedMp3SeekTest {
  private static final int FRAMES = 16000;
  private static long frameTime(int frame) { return frame * 1152L * 1000000 / 44100; }

  // MPEG-1 Layer III headers with variable bitrate, plus a deliberately coarse
  // Xing TOC. Payloads carry frame IDs; no decoder is involved in this test.
  private static byte[] fixture(boolean xing) {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    int[] positions = new int[FRAMES + 1];
    byte[] header = new byte[417];
    ByteBuffer h = ByteBuffer.wrap(header);
    h.putInt(0xfffb9000);
    h.position(36);
    h.putInt(xing ? 0x58696e67 : 0x496e666f); // Xing / Info
    h.putInt(7); h.putInt(FRAMES); h.putInt(0);
    bytes.writeBytes(header);
    for (int i = 0; i < FRAMES; i++) {
      positions[i] = bytes.size();
      boolean high = xing && i % 160 < 70;
      int bitrate = high ? 320000 : 64000;
      byte[] frame = new byte[144 * bitrate / 44100];
      ByteBuffer f = ByteBuffer.wrap(frame);
      f.putInt(high ? 0xfffbe000 : 0xfffb5000);
      f.position(8); f.putInt(i);
      bytes.writeBytes(frame);
    }
    positions[FRAMES] = bytes.size();
    byte[] result = bytes.toByteArray();
    ByteBuffer.wrap(result).putInt(48, result.length);
    for (int i = 0; i < 100; i++) {
      result[52 + i] = (byte) (positions[FRAMES * i / 100] * 256L / result.length);
    }
    return result;
  }

  private static final class Capture implements ExtractorOutput, TrackOutput {
    SeekMap seekMap;
    final ByteArrayOutputStream pending = new ByteArrayOutputStream();
    final List<Long> errors = new ArrayList<>();
    public TrackOutput track(int id, int type) { return this; }
    public void endTracks() {}
    public void seekMap(SeekMap map) { seekMap = map; }
    public void format(Format format) {}
    public int sampleData(DataReader input, int length, boolean allowEnd, int part) throws IOException {
      byte[] buffer = new byte[length];
      int read = input.read(buffer, 0, length);
      if (read > 0) pending.write(buffer, 0, read);
      return read;
    }
    public void sampleData(ParsableByteArray input, int length, int part) {
      byte[] buffer = new byte[length]; input.readBytes(buffer, 0, length);
      pending.writeBytes(buffer);
    }
    public void sampleMetadata(long timeUs, int flags, int size, int offset, CryptoData crypto) {
      byte[] frame = pending.toByteArray(); pending.reset();
      int id = ByteBuffer.wrap(frame).getInt(8);
      errors.add(timeUs - frameTime(id));
    }
  }

  private static DefaultExtractorInput input(byte[] bytes, long position) {
    int[] cursor = {(int) position};
    return new DefaultExtractorInput((target, offset, length) -> {
      if (cursor[0] == bytes.length) return -1;
      int count = Math.min(length, bytes.length - cursor[0]);
      System.arraycopy(bytes, cursor[0], target, offset, count);
      cursor[0] += count;
      return count;
    }, position, bytes.length);
  }

  private static Capture seek(Extractor extractor, byte[] bytes, long... targets) throws Exception {
    Capture capture = new Capture(); extractor.init(capture);
    DefaultExtractorInput in = input(bytes, 0);
    PositionHolder holder = new PositionHolder();
    while (capture.seekMap == null) assertNotEquals(Extractor.RESULT_END_OF_INPUT, extractor.read(in, holder));
    for (long target : targets) {
      long position = capture.seekMap.getSeekPoints(target).first.position;
      extractor.seek(position, target);
      in = input(bytes, position);
      capture.pending.reset();
      int previous = capture.errors.size();
      while (capture.errors.size() < previous + 8) {
        assertNotEquals(Extractor.RESULT_END_OF_INPUT, extractor.read(in, holder));
      }
    }
    extractor.release();
    return capture;
  }

  @Test void coarseXingSeeksReproduceLargeTimestampErrors() throws Exception {
    Capture stock = seek(new Mp3Extractor(), fixture(true), 98338000L, 97000000L);
    assertTrue(stock.errors.stream().anyMatch(error -> Math.abs(error) > 100000),
        "The baseline must reproduce a real frame/time mismatch");
  }

  @Test void indexedColdAdjacentBackwardAndLateSeeksKeepActualFrameTimes() throws Exception {
    Capture indexed = seek(new JlexaIndexedMp3Extractor(), fixture(true),
        98338000L, 97000000L, 98338000L, 380000000L, 1000000L);
    assertTrue(indexed.errors.size() >= 40);
    // Index anchors and sample durations are integer microseconds. Repeated
    // seeks can accumulate a few rounding microseconds, below one PCM sample.
    for (long error : indexed.errors) assertTrue(Math.abs(error) <= 10, "Timestamp error: " + error);
  }

  @Test void cbrInfoHeaderAlsoRetainsExactFrameTimes() throws Exception {
    Capture indexed = seek(new JlexaIndexedMp3Extractor(), fixture(false), 98338000L, 1000000L);
    for (long error : indexed.errors) assertTrue(Math.abs(error) <= 10, "Timestamp error: " + error);
  }
}
