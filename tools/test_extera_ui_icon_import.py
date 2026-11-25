"""Run with: py -m unittest discover -s tools -p test_extera_ui_icon_import.py"""
import unittest
import xml.etree.ElementTree as ET
from import_extera_ui_icons import vector_svg


class VectorConversionTests(unittest.TestCase):
    def svg(self, paths):
        return ET.fromstring(vector_svg(('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:viewportWidth="24" android:viewportHeight="24">' + paths + '</vector>').encode()))

    def testStrokeOnlyPathsDoNotAcquireAnImplicitFill(self):
        svg = self.svg('<path android:pathData="M2 12h20" android:strokeColor="#ffffffff" android:strokeWidth="1.67" android:strokeLineCap="round"/>')
        path = svg[0]
        self.assertEqual(path.attrib['fill'], 'none')
        self.assertEqual(path.attrib['stroke-width'], '1.67')
        self.assertEqual(path.attrib['stroke-linecap'], 'round')
        self.assertEqual(path.attrib['d'], 'M2 12h20')

    def testEvenOddHolesAndGroupOrderSurvive(self):
        svg = self.svg('<group><path android:pathData="M1 1h22v22H1z M4 4v16h16V4z" android:fillColor="#FFFFFFFF" android:fillType="evenOdd"/></group>')
        self.assertEqual(svg[0][0].attrib['fill-rule'], 'evenodd')
        self.assertEqual(len(svg[0]), 1)

    def testUnsupportedTransformsFailInsteadOfChangingArtwork(self):
        with self.assertRaises(AssertionError):
            self.svg('<group android:rotation="45"/>')

    def testNonWhitePaintFailsInsteadOfLosingItsMeaning(self):
        with self.assertRaises(AssertionError):
            self.svg('<path android:pathData="M1 1h2" android:fillColor="#ff000000"/>')


if __name__ == '__main__':
    unittest.main()
