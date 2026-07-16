namespace ZSpeak.Core.Models;

public sealed class AppStateMachine
{
    public AppStatus Current { get; private set; } = AppStatus.Loading;

    public void TransitionTo(AppStatus next)
    {
        if (next == Current)
        {
            return;
        }

        var allowed = Current switch
        {
            AppStatus.Loading => next is AppStatus.Ready or AppStatus.Error,
            AppStatus.Ready => next is AppStatus.Loading or AppStatus.Recording or AppStatus.Error,
            AppStatus.Recording => next is AppStatus.Transcribing or AppStatus.Ready or AppStatus.Error,
            AppStatus.Transcribing => next is AppStatus.Ready or AppStatus.Error,
            AppStatus.Error => next == AppStatus.Loading,
            _ => false
        };
        if (!allowed)
        {
            throw new InvalidOperationException($"Transição inválida: {Current} -> {next}.");
        }

        Current = next;
    }
}
