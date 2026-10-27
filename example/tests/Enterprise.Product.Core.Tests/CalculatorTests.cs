using Enterprise.Product.Core;
using Xunit;

namespace Enterprise.Product.Core.Tests;

public class CalculatorTests
{
    [Fact] public void Add_works() => Assert.Equal(5, Calculator.Add(2, 3));
    [Fact] public void Multiply_works() => Assert.Equal(12, Calculator.Multiply(3, 4));
}
