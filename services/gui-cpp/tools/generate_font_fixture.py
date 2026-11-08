from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory

from fontTools import subset
from fontTools.designspaceLib import AxisDescriptor, DesignSpaceDocument, InstanceDescriptor, SourceDescriptor
from fontTools.ttLib import TTCollection, TTFont
from fontTools.varLib import build

def main():
    root = Path(__file__).resolve().parents[3]
    original = root / 'assets/JetBrainsMono-Regular.ttf'
    output = root / 'services/gui-cpp/tests/fixtures/metrics-variable.ttf'
    family = 'Telar Metrics Fixture'
    font = TTFont(original, recalcTimestamp=False)
    subsetter = subset.Subsetter()
    subsetter.populate(text=' Mg@')
    subsetter.subset(font)
    for identifier, text in {1: family, 2: 'Regular', 3: 'TelarMetricsFixture-Regular', 4: family + ' Regular', 6: 'TelarMetricsFixture-Regular', 16: family, 17: 'Regular'}.items():
        font['name'].removeNames(nameID=identifier)
        font['name'].setName(text, identifier, 3, 1, 0x409)
        font['name'].setName(text, identifier, 1, 0, 0)
    font['OS/2'].fsSelection |= 0x80
    with TemporaryDirectory(prefix='telar-font-fixture-') as temporary:
        work = Path(temporary)
        document = DesignSpaceDocument()
        axis = AxisDescriptor()
        axis.name = 'Width'
        axis.tag = 'wdth'
        axis.minimum = axis.default = 100
        axis.maximum = 200
        document.addAxis(axis)
        for index, coordinate in enumerate([100, 200]):
            master = deepcopy(font)
            if index:
                master['hhea'].ascent += 200
                master['hhea'].descent -= 100
                master['hhea'].lineGap += 50
                master['OS/2'].sTypoAscender += 200
                master['OS/2'].sTypoDescender -= 100
                master['OS/2'].sTypoLineGap += 50
                master['post'].underlineThickness += 90
                for name, (advance, bearing) in list(master['hmtx'].metrics.items()):
                    master['hmtx'].metrics[name] = (advance * 3 // 2, bearing)
            filename = work / f'master-{index}.ttf'
            master.save(filename)
            source = SourceDescriptor()
            source.path = str(filename)
            source.name = f'master-{index}'
            source.familyName = family
            source.styleName = 'Regular' if not index else 'Wide'
            source.location = {'Width': coordinate}
            source.copyInfo = source.copyLib = source.copyFeatures = not index
            document.addSource(source)
            instance = InstanceDescriptor()
            instance.familyName = family
            instance.styleName = source.styleName
            instance.location = source.location.copy()
            document.addInstance(instance)
        variable, _, _ = build(document)
        variable.recalcTimestamp = False
        variable['head'].modified = font['head'].modified
        variable.save(output)
        static = deepcopy(font)
        for identifier, value in {1: 'Telar Static Fixture', 3: 'TelarStaticFixture-Regular', 4: 'Telar Static Fixture Regular', 6: 'TelarStaticFixture-Regular', 16: 'Telar Static Fixture'}.items():
            static['name'].removeNames(nameID=identifier)
            static['name'].setName(value, identifier, 3, 1, 0x409)
            static['name'].setName(value, identifier, 1, 0, 0)
        collection = TTCollection()
        collection.fonts = [static, variable]
        collection.save(output.with_name('metrics-collection.ttc'))
        print(f'{output}: {output.stat().st_size} bytes')


if __name__ == "__main__":
    main()
