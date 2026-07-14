open Rake

let expect_valid source =
  match Layout.validate ~filename:"layout-test.rk" source with
  | Ok () -> ()
  | Error message -> failwith ("expected valid layout: " ^ message)

let contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec search index =
    index + needle_length <= haystack_length
    && (String.sub haystack index needle_length = needle || search (index + 1))
  in
  needle_length = 0 || search 0

let expect_invalid fragment source =
  match Layout.validate ~filename:"layout-test.rk" source with
  | Ok () -> failwith ("expected invalid layout containing: " ^ fragment)
  | Error message ->
      if not (contains message fragment)
      then failwith ("unexpected layout diagnostic: " ^ message)

let () =
  expect_valid
    "crunch add(\n  left: f32s,\n  right: f32s\n) -> f32s:\n  return left + right\n\ncrunch id(value: f32s) -> f32s:\n  return value\n";
  expect_valid
    "stack Samples {\n  f32: value;\n}\n\n~~ a comment does not affect layout\nrun copy(input: pack Samples, <count: i64>) -> f32:\n  for chunk in input using f32s up to <count>:\n    yield chunk.value\n";
  expect_invalid "indented body"
    "crunch broken(value: f32s) -> f32s:\nreturn value\n";
  expect_invalid "enclosing body"
    "crunch broken(value: f32s) -> f32s:\n  let copy = value\n return copy\n";
  expect_invalid "tabs"
    "crunch broken(value: f32s) -> f32s:\n\treturn value\n"
