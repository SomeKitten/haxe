class Main2 {
	static function main() {
		trace("TestFoo", TestFoo.macros);
		trace("TestBar", TestBar.macros);
	}
}

class Async {
	public function done() {}
}

@:autoBuild(Macro2.buildTest())
class BaseTest {}

class TestFoo extends BaseTest {
	@:async
	function test() async.done();
}

@:autoBuild(Macro2.autoAsync())
class AsyncTest extends BaseTest {}

class TestBar extends AsyncTest {
	function test() async.done();
}