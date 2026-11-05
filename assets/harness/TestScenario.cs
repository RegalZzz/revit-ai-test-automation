using System;
using System.Linq;
using Autodesk.Revit.DB;

namespace __HARNESS_NAME__
{
    public static class TestScenario
    {
        // Replace this scope and extend Run when integrating a real plugin.
        public static string Scope { get { return "api-smoke"; } }

        public static void Run(TestContext context)
        {
            Document document = context.Document;
            Level level;
            ViewPlan view;
            DetailCurve line;
            const double elevationMm = 12345.0;
            using (var transaction = new Transaction(document, "Prepare API smoke scene"))
            {
                transaction.Start();
                level = Level.Create(document, elevationMm / 304.8);
                level.Name = "Integration test " + context.RunId;
                ViewFamilyType family = new FilteredElementCollector(document).OfClass(typeof(ViewFamilyType))
                    .Cast<ViewFamilyType>().First(type => type.ViewFamily == ViewFamily.FloorPlan);
                view = ViewPlan.Create(document, family.Id, level.Id);
                view.Name = "API smoke " + context.RunId;
                view.Scale = 100;
                double z = level.Elevation;
                line = document.Create.NewDetailCurve(view, Line.CreateBound(new XYZ(0, 0, z), new XYZ(10, 0, z)));
                document.Create.NewDetailCurve(view, Line.CreateBound(new XYZ(0, 0, z), new XYZ(0, 10, z)));
                view.CropBox = new BoundingBoxXYZ { Min = new XYZ(-2, -2, z - 1), Max = new XYZ(12, 12, z + 1) };
                view.CropBoxActive = true;
                view.CropBoxVisible = false;
                transaction.Commit();
            }
            context.Check(Math.Abs(level.Elevation * 304.8 - elevationMm) < 0.001, "Created level has the independently specified elevation");
            context.Check(view.GenLevel.Id == level.Id, "Test floor plan belongs to the test level");
            context.Check(Math.Abs(line.GeometryCurve.Length * 304.8 - 3048.0) < 0.001, "Detail line is 3048 mm long");
            context.Check(new FilteredElementCollector(document, view.Id).OfClass(typeof(CurveElement)).GetElementCount() == 2,
                "The smoke view contains exactly two detail curves");
            context.ExportView(view, "api-smoke");
        }
    }
}
