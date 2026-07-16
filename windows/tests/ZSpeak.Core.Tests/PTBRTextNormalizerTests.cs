using ZSpeak.Core.Text;

namespace ZSpeak.Core.Tests;

public sealed class PTBRTextNormalizerTests
{
    [Theory]
    [InlineData("Olamundo, teste local.", "Olá mundo, teste local.")]
    [InlineData("abro um pulo request agora", "abro um pull request agora")]
    [InlineData("postgresql, kubernetes e redis", "PostgreSQL, Kubernetes e Redis")]
    [InlineData("  texto   com   espaços  ", "texto com espaços")]
    public void Normalize_AplicaRegrasLocais(string input, string expected) =>
        Assert.Equal(expected, PTBRTextNormalizer.Normalize(input));
}
