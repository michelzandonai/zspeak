using System.Text.RegularExpressions;

namespace ZSpeak.Core.Text;

public static partial class PTBRTextNormalizer
{
    private static readonly (Regex Pattern, string Replacement)[] TechnicalAliases =
    {
        (Word("pulo request"), "pull request"),
        (Word("postgre sql"), "PostgreSQL"),
        (Word("postgresql"), "PostgreSQL"),
        (Word("kubernetes"), "Kubernetes"),
        (Word("redis"), "Redis")
    };

    public static string Normalize(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return string.Empty;
        }

        var result = Whitespace().Replace(text.Trim(), " ");
        result = Olamundo().Replace(result, "Olá mundo");
        foreach (var (pattern, replacement) in TechnicalAliases)
        {
            result = pattern.Replace(result, replacement);
        }

        return result;
    }

    private static Regex Word(string value) => new(
        $@"(?<![\p{{L}}\p{{N}}]){Regex.Escape(value)}(?![\p{{L}}\p{{N}}])",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    [GeneratedRegex(@"\s+", RegexOptions.Compiled)]
    private static partial Regex Whitespace();

    [GeneratedRegex(@"\bolamundo\b", RegexOptions.IgnoreCase | RegexOptions.Compiled)]
    private static partial Regex Olamundo();
}
