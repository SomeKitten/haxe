class Parent {}
class Child extends Parent {}

interface I {
    public function test<T>():T;
}

class C implements I {
    public function test<T:Child>():T {
		return null;
	}
}

function main() {

}